---
name: ubuntu-vmwin-gpuout-helper
description: 處理「GPU 掉卡」：Ubuntu KVM 直通 NVIDIA CMP 170HX（cmpunlocker 解鎖）給 Windows 11 虛擬機時，卡從裝置管理員消失、VM 凍結、藍屏（0x1A/0x139/0x7E）、DSH/Electron renderer 崩潰。Use when the user says 掉卡/卡掉了/GPU 掉了/卡不見了/Device Manager code 43 on a KVM host, or the passthrough GPU/VM crashes under CUDA load (ComfyUI). Also covers 新機重設 (re-setup) of the same stack.
---

# Ubuntu + Win11 虛擬機 GPU 掉卡救援

本 skill 固化自一次實際成功案例：4× CMP 170HX（cmpunlocker 解鎖 64GB）主機，直通卡在 ComfyUI 滿載下反覆掉卡、VM 反覆藍屏。套用下述三層架構後不再掉卡。
環境細節與完整說明見 bundle 根目錄的 `README.md`；踩坑史見 `docs/pitfall-log.md`；腳本在 `scripts/`（host 端 bash、guest 端 PowerShell/Node）。

## 核心原理（先讀，避免誤判）

1. **cmpunlocker 的解鎖存在 GSP boot-state 暫存器**，任何 GPU reset（SBR/D3/驅動 reset/VM 電源循環）都會讓 GSP 重開機、暫存器回到 factory 值 → 解鎖被丟。**「掉卡」＝「解鎖被丟＋驅動認不出卡」，不是卡壞了。**
2. **`Booter 0x31` 是開機噪音**：host 每次開機所有 CMP 卡都會打一批（每卡數十次）`NVRM: ... executeBooterUcode_TU102: Booter failed ... 0x31`，伴隨一次 PCIe retrain 降 `speed=1`，之後 `LnkSta` 恢復 `5GT/s x16`。不要據此判定某卡快壞（本案例曾被誤導）。
3. **VM 藍屏 `0x1A`/`0x139`/`0x7E`** ＝ GPU 驅動/顯存層在 CUDA 滿載時糟蹋記憶體、GPU 當住（硬體/韌體層不穩）。TDR/電源設定擋不住硬藍屏；能做的是讓救援快、軟掉卡自動恢復、必要時減負或換卡。
4. **DSH（Electron）renderer 崩潰**是下游症狀：guest 的 DSH 加 `--disable-gpu`（WARP 軟渲染）後消失。
5. **紅線：guest 的 170HX 驅動是特別版本（案例 580.88），不要升級**成一般版驅動。

## 診斷流程（卡掉了 / 用戶說「掉卡」）

按序執行（host 端命令需 sudo；`<BDF>`＝直通卡，如 `0000:44:00.0`）：

1. **看解鎖狀態**：`/usr/local/lib/cmpunlocker/gsp-restore show <BDF>`
   - 出現 `needs restore` → 軟掉卡 → 走【救援-A】
   - 正常但 guest 仍報錯 → 走【救援-B】（完整救回）
2. **看 host 日誌**：`sudo dmesg | grep -iE 'xid|aer|retrain|booter' | tail -30`
   - 只有開機時的 Booter 0x31 一批 → 噪音，忽略
   - 有 Xid / AER 錯誤 → 記錄（硬體層線索）
3. **看 VM 狀態**：`virsh domstate <domain>`（注意：中文 locale 會回「執行中」，字串比對不可靠）
4. **VM 藍屏時**（guest 能開機後）：在 guest 跑 `scripts/guest/read-bugchecks.ps1` 抓 bugcheck 碼
   - minidump 檔頭是 `PAGE`（PAGEDU64）不是 `MDMP` → 用事件日誌，別用 MDMP 解析器

## 救援流程

### A. 軟掉卡（GSP needs restore，VM 可能還在跑）
- **wait ≤2 分鐘**：`gsp-keepalive.timer`（每 2 分鐘）通常已自動 re-arm → 複查 `gsp-restore show`
- 沒恢復 → 直接手動：`/usr/local/lib/cmpunlocker/gsp-restore restore <BDF>`
- guest 端若卡已重現（裝置管理員）→ 驗證 `nvidia-smi`

### B. 硬掉卡／VM 凍結（完整救回）
```bash
sudo bash <path-to>/scripts/host/fix-gpu.sh <domain> <BDF>
```
流程：`gsp-restore show` → 停 VM（`virsh shutdown` 等 90s → `virsh destroy` fallback，**destroy fallback 必須保留**，因為 domstate 受 locale 影響）→ `passthrough.sh restore <BDF>`（處理 ACR stuck state）→ `virsh start` → 驗證。
注意：**腳本要放在 host 上執行**（例如由 agent 經 SSH 跑）。若 VM 死了、agent 自己也跑在 VM 裡 → 先告訴用戶「我會重連到 host 執行」，用 host 端 SSH 跑（detached：`setsid nohup sudo bash fix-gpu.sh ... > /tmp/fix-gpu.log 2>&1 &`），VM 起來後再讀 log。

### C. 藍屏（硬層）
- 讀 `read-bugchecks.ps1` 輸出；`0x1A`/`0x139`/`0x7E` → 告知用戶這是**滿載下顯存/驅動層不穩**，非配置錯誤
- 依 README §7 給後備選項：減負 → 換另一張 CMP 卡試（判斷系統性/單卡）→ 非 CMP 卡直通 → ComfyUI 移去 host

## 重設流程（新機 / 洗機後）

照 README §5 的 checklist 走；順序：host cmpunlocker（nvidia-open 610+、Secure Boot off）→ udev 規則 → 確認 `cmpunlocker-passthrough.service` → 部署 keepalive（`install-keepalive.sh`）→ 部署 fix-gpu.sh（改 BDF 預設值）→ VM hostdev → guest 特別版驅動（**勿升級**）→ `gpu-settings.ps1` →（可選）`dsh-disable-gpu.mjs` → 滿載驗證 30 分鐘。

## 換卡（例如 44→43）時要改什麼

- **keepalive / udev / arm 服務：不用改**（自動偵測 vfio-pci 卡 / 依裝置 ID / arm 全部卡）
- **要改**：①VM 的 hostdev PCI bus（44→43）②fix-gpu.sh 的 BDF 預設值（或跑時帶參數）

## 常見坑（不要重蹈）

- `virsh domstate` 的 locale 字串（「執行中」vs `running`）
- 被 Booter 0x31 誤導去判定單卡故障（先比對 LnkSta 是否恢復 x16）
- 用 MDMP 工具解析 PAGEDU64 的 minidump（檔頭 `PAGE`）
- 把 host 端含 `━`（U+2501）等字的輸出直接 print 到 cp950 PowerShell → `UnicodeEncodeError`；改寫 UTF-8 檔
- `nvidia-smi -pm 1` 在此平台「not supported」＝ N/A，不是錯誤
- Win11 24H2 的 `powercfg` 已無 PCI Express 子群組的 Link State PM 設定 → N/A，不是錯誤
- guest 的 170HX 驅動（特別版）**不要升級**
- **不要動 host 上跑 vLLM 的那張卡**（它支撐著你的 agent session 本身）
