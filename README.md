# ubuntu-vmwin-gpuout-helper

Ubuntu（KVM/QEMU）上把 **NVIDIA CMP 170HX**（[cmpunlocker](#) 解鎖 64GB）直通給 **Windows 11 虛擬機**時「**GPU 掉卡**」問題的完整解決方案：診斷、救援、自動修復，以及**買新電腦／洗機後的 reusable 重設流程**。

> 本 repo 固化自一次實際成功的救援案例（2026-11）：4× CMP 170HX 主機，直通卡在 ComfyUI（CUDA 滿載）下反覆掉卡、VM 反覆藍屏（`0x1A`／`0x139`／`0x7E`）。套用本 repo 的三層架構後，**不再掉卡**。

---

## 目錄

1. [適用場景](#1-適用場景)
2. [根因（重要理解）](#2-根因重要理解)
3. [三層救援架構](#3-三層救援架構本-repo-核心)
4. [快速救援（卡已掉）](#4-快速救援卡已掉)
5. [新機／洗機重設流程（reusable checklist）](#5-新機洗機重設流程reusable-checklist)
6. [除錯清單](#6-除錯清單)
7. [藍屏仍持續時的後備選項](#7-藍屏仍持續時的後備選項)
8. [隱私聲明](#8-隱私聲明)
9. [作為 DSH skill 安裝](#9-作為-dsh-skill-安裝)

---

## 1. 適用場景

| 項目 | 案例環境 | 你的環境要求 |
|---|---|---|
| Host OS | Ubuntu 26.04（kernel 7.x） | Ubuntu（KVM/libvirt），**Secure Boot 關閉** |
| 主機板 | AMD X399（Threadripper）+ VPS | 任何支援 KVM 直通的 x86-64 平台 |
| GPU | 4× CMP 170HX（GA100，cmpunlocker 解鎖 64GB） | CMP 170HX 8GB/10GB 版（解鎖 64/40GB）|
| 直通卡 | 0000:44:00.0 → VM `win11` | 任一 CMP 卡 |
| 其他卡 | 1× 跑 vLLM、2× host 閒置 | 任意 |
| Guest OS | Windows 11（24H2） | Windows 10/11 |
| Guest 工作負載 | ComfyUI（重 CUDA） | 任何 CUDA / 3D 負載 |
| Guest GPU 驅動 | **580.88（170HX 特別版本，勿升級）** | 170HX 對應的特別驅動 |

**典型症狀**（符合任何一條就適用本 repo）：

- Guest 裝置管理員：NVIDIA 卡消失、變成「未知裝置」或錯誤代碼 43
- VM 整個凍結、需硬重置（Kernel-Power 41）
- VM 藍屏，bugcheck 為 `0x1A`／`0x139`／`0x7E`
- Guest 內的 DSH／Electron 應用 renderer 反覆崩潰
- 掉卡多發生在**滿載（ComfyUI 出圖）之後**

## 2. 根因（重要理解）

1. **cmpunlocker 的解鎖存在 GSP boot-state 暫存器**。任何 GPU reset（SBR、D3、驅動 reset、VM 電源循環）都會讓 GSP 重新開機、暫存器回到 factory 值 → **解鎖被丟**。所以「掉卡」本質上是「解鎖被丟＋驅動再也認不出卡」，不是卡壞了。
2. **`Booter 0x31` 是開機噪音，不是故障**：host 每次開機，**所有** CMP 卡都會在一小段時間內打出大量 `NVRM: ... executeBooterUcode_TU102: Booter failed ... 0x31`（案例中每卡 55 次），並伴隨一次 PCIe retrain 降速到 `speed=1`，之後 `LnkSta` 恢復 `5GT/s x16`。這是該驅動／韌體組合的**正常開機噪音**——**不要**據此判定「某張卡快壞了」（本案例就曾被它誤導）。
3. **VM 藍屏 `0x1A`／`0x139`／`0x7E`**：`0x1A` MEMORY_MANAGEMENT（記憶體結構被糟蹋）、`0x139` DPC_WATCHDOG_VIOLATION（GPU 驅動 DPC 卡死＝GPU 沒回應）、`0x7E` SYSTEM_SERVICE_EXCEPTION（驅動 access violation）。三者合起來＝**GPU 驅動／顯存層在 CUDA 滿載時糟蹋記憶體、GPU 當住**，屬**硬體／韌體層不穩**。Windows 端 TDR／電源設定**擋不住硬藍屏**，只能：①讓救援快 ②讓軟掉卡自動恢復 ③（需要時）減負或換卡。
4. **DSH（Electron）renderer 崩潰**是 GPU 路徑的**下游症狀**：在 guest 的 DSH 加 `--disable-gpu`（改走 WARP 軟渲染）後完全消失。DSH 的顯示是虛擬適配器，NVIDIA 卡只負責計算/3D，所以關硬體加速不影響 DWM。

## 3. 三層救援架構（本 repo 核心）

| 層 | 工具 | 位置 | 作用 |
|---|---|---|---|
| **L1 自動修復**（軟掉卡） | `gsp-keepalive`（systemd timer，每 2 分鐘） | host | 自動偵測**綁 vfio-pci**（＝當下直通中）的 CMP 卡，GSP 解鎖丟了就 re-arm。**VM 不用時完全閒置、零影響** |
| **L2 完整救援**（硬掉卡／凍結） | `fix-gpu.sh` | host | 關 VM（graceful 90s → destroy fallback）→ `passthrough.sh restore <BDF>`（會處理 ACR stuck state）→ 開 VM |
| **L3 藍屏診斷** | `read-bugchecks.ps1` | guest | 從事件日誌抓 bugcheck 碼＋參數＋dump 檔（minidump 是 **PAGEDU64** 格式，**不要**用 MDMP 工具解析） |
| 輔助 | `gpu-settings.ps1` | guest | `TdrDelay=60` 等 guest 端設定（此平台：persistence mode 不支援；Win11 24H2 已移除 PCIe link PM 設定） |
| 輔助 | `dsh-disable-gpu.mjs` | guest | DSH `--disable-gpu` 補丁（**同長度 in-place**，保留 asar 檔案 hash） |
| 輔助 | `udev-99-cmpunlocker.rules.example` | host | vfio-pci bind 時自動 `gsp-restore %k`（cmpunlocker 自帶，此處備份一份） |

## 4. 快速救援（卡已掉）

在 **host** 上（需 `virsh` 與 root）：

```bash
sudo bash fix-gpu.sh <vm-domain> <BDF>
# 例：sudo bash fix-gpu.sh win11 0000:44:00.0
```

流程（腳本內含時間戳日誌）：

1. `gsp-restore show <BDF>` 看當前解鎖狀態
2. 停 VM：先 `virsh shutdown` 等 90s，未到 `shut off` 就 `virsh destroy`
   （註：`virsh domstate` 的字串**受 locale 影響**——中文環境會回「執行中」而非 `running`，所以 destroy fallback 是設計上必要的）
3. `passthrough.sh restore <BDF>`（cmpunlocker 附帶；會處理 GSP ACR stamp 卡住：rmmod 保護模組 → reset → 重綁 → 重新 arm）
4. `virsh start <vm-domain>`，再確認狀態

**驗證**（guest 內）：`nvidia-smi` 顯示 64GB、溫度/功耗正常；host 端 `gsp-restore show <BDF>` 不該再出現 `needs restore`。

## 5. 新機／洗機重設流程（reusable checklist）

> 買新電腦或洗機後，照這一份走完即可復現。所有腳本在 [`scripts/`](scripts/)。

### 5.1 Host（Ubuntu）

1. **裝 cmpunlocker（v0.5）**
   - 前置：`nvidia-open 610.xx.xx+`（libs + firmware，**host 端**要求）、`kernel-headers-$(uname -r)`、Secure Boot 關閉、首次安裝需網路
   - `sudo ./install.sh`（`--profile=8gb` / `--profile=10gb` 可指定記憶體幾何）→ 重開機
2. **udev 規則**：把 [`scripts/host/udev-99-cmpunlocker.rules.example`](scripts/host/udev-99-cmpunlocker.rules.example) 放為 `/etc/udev/rules.d/99-cmpunlocker-passthrough.rules`（依裝置 ID 匹配，四張卡都覆蓋；vfio-pci bind 時自動 re-arm）
3. **確認 boot-time arm 服務**：`cmpunlocker-passthrough.service`（開機 arm 全部卡）`systemctl is-active`
4. **部署 keepalive（L1）**：
   ```bash
   sudo bash install-keepalive.sh   # 複製 scripts/host/ 內的 keepalive 三件套、enable timer、手動跑一次驗證
   ```
5. **部署 fix-gpu.sh（L2）**：複製到 host，把 `BDF` 預設值改成你的直通卡
6. **直通卡選定**：hostdev 的 PCI bus = 你要直通的 BDF；換卡時只需改 hostdev ＋ fix-gpu.sh 預設值（keepalive / udev / arm 服務全自動跟隨，**不用改**）

### 5.2 VM（KVM）

1. VM XML 加 hostdev（`managed=yes`），PCI 對齊 BDF
2. **Guest 驅動：用 170HX 的特別版本驅動，不要升級成一般版**（案例為 580.88）。這是本案例的**明確紅線**：該驅動是 170HX 特別版本，升級可能破壞相容性
3. 以**提升權限**跑 [`scripts/guest/gpu-settings.ps1`](scripts/guest/gpu-settings.ps1)（`TdrDelay=60` 等；全部可逆）
4. 若 guest 的 DSH 有 renderer 崩潰：跑 [`scripts/guest/dsh-disable-gpu.mjs`](scripts/guest/dsh-disable-gpu.mjs)

### 5.3 驗證

- Guest：`nvidia-smi`（64GB、無 Xid）→ 跑一段**滿載** CUDA（ComfyUI 出圖）30 分鐘觀察
- Host：`sudo dmesg | grep -iE 'xid|aer|retrain|booter'`、`gsp-restore show <BDF>`、`systemctl status gsp-keepalive.timer`

## 6. 除錯清單

| 症狀 | 查什麼 | 處理 |
|---|---|---|
| Guest GPU 消失／code 43 | host `gsp-restore show <BDF>` | 出現 `needs restore` → keepalive 應已自動補回；沒補到 → `fix-gpu.sh` |
| VM 凍結 | `virsh domstate`（注意 locale） | `fix-gpu.sh`（走 destroy 路徑） |
| VM 藍屏 | guest `read-bugchecks.ps1` | `0x1A`/`0x139`/`0x7E` → 滿載下顯存/驅動層不穩 → 見 [§7](#7-藍屏仍持續時的後備選項) |
| `dmesg` 一堆 `Booter 0x31` | 比對 `LnkCap`/`LnkSta` | 恢復到 `5GT/s x16` → **開機噪音，忽略** |
| `virsh domstate` 回中文 | 主機 locale | 腳本已含 destroy fallback，不需處理 |
| minidump 開頭是 `PAGE`（不是 `MDMP`） | 檔頭 4 bytes | PAGEDU64 格式（kernel dump），用事件日誌（`read-bugchecks.ps1`），別用 MDMP 解析器 |
| 腳本印 host 輸出到 cp950 終端炸 `UnicodeEncodeError` | PowerShell 編碼 | 把 host 輸出寫進 UTF-8 檔再讀，不要直接 print |
| `nvidia-smi -pm 1` 回「not supported on this platform」 | 平台限制 | 此平台 N/A，跳過（不是錯誤） |
| `powercfg` 查 PCIe Link State PM 回「不存在」 | Win11 24H2 已移除該設定 | N/A，跳過（不是錯誤） |

## 7. 藍屏仍持續時的後備選項

依序考慮：

1. **降低 ComfyUI 負載**（batch size、解析度、VRAM 使用量）
2. **換另一張 CMP 卡直通**，判斷系統性 vs 單卡（案例：0b→44 換卡後照掉 → 判定系統性）
3. **改用非 CMP（stock datacenter）卡直通給 VM**，CMP 卡留給 host（vLLM 等）
4. **ComfyUI 改在 host 卡跑**（Linux CUDA，免直通）

## 8. 隱私聲明

本 repo 已做隱私脫敏：**不含** IP 位址、帳號密碼、API token、特定主機名或 Windows 使用者名稱；環境特定值皆以佔位符或腳本預設參數呈現。你覆用時請以自己的值取代。

## 9. 作為 DSH skill 安裝

本 repo 內含 DSH（DeepSeek Harness）skill（[`skills/ubuntu-vmwin-gpuout-helper/SKILL.md`](skills/ubuntu-vmwin-gpuout-helper/SKILL.md)）。DSH 內建的 filesystem skill provider 會**自動掃描 `~/.dsh/skills/`**（＝ `$DSH_HOME/skills`，base 組態預設掛載、含檔案監控），所以安裝只需把 skill 資料夾複製過去：

```bash
git clone https://github.com/18gogogo/ubuntu-vmwin-gpuout-helper.git
cd ubuntu-vmwin-gpuout-helper
# Linux / macOS:
mkdir -p ~/.dsh/skills
cp -r skills/ubuntu-vmwin-gpuout-helper ~/.dsh/skills/
```

```powershell
# Windows (PowerShell):
git clone https://github.com/18gogogo/ubuntu-vmwin-gpuout-helper.git
cd ubuntu-vmwin-gpuout-helper
New-Item -ItemType Directory -Force "$env:USERPROFILE\.dsh\skills" | Out-Null
Copy-Item -Recurse -Force skills\ubuntu-vmwin-gpuout-helper "$env:USERPROFILE\.dsh\skills\"
```

安裝後**無需重啟 DSH**（provider 有檔案監控，目錄變動會自動重新發現）；session 的 skill catalog 會出現 `ubuntu-vmwin-gpuout-helper`。當你說「掉卡了／GPU 掉了」，agent 會自動依 skill 裡的診斷→救援→驗證流程處理。

> 備註：把整包 repo 用 DSH Plugin Manager 以 bundle 形式安裝是可行的延伸（需在 `package.json` 加 `dsh.bundle.patch` 宣告），目前以 `~/.dsh/skills/` 複製為標準安裝方式——對「新機／洗機覆用」而言這一步最簡單、最可靠。

## License

[MIT](LICENSE)
