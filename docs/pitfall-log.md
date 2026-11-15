# 踩坑記錄（Pitfall Log）

本案例（2026-11，4× CMP 170HX，Ubuntu host + Win11 VM）的完整踩坑史。按主題整理，供複用時避坑。

## 時間軸（摘要）

- 症狀開始：直通卡（先 0b 後 44）在 ComfyUI 滿載後反覆掉卡；VM 反覆藍屏；DSH renderer 崩潰
- 診斷期：誤判「0b 卡快壞」→ 被 host 開機日誌否定（Booter 0x31 四卡都有）
- 處置期：DSH `--disable-gpu` 補丁 → guest 端 TDR/電源設定（方案 2）→ 換卡 0b→44 → host GSP keepalive（方案 3）
- 結果：不再掉卡
- 第二輪（2026-11-14/15）：DSH 自動更新 rc.1→rc.3 **沖掉 asar 補丁** → renderer＋host（`0xC0000005`）崩潰回潮；**host 靜默硬掛死 ×2**（03:18、04:32）連累 VM；bsi 常態值造成誤判；host 正常 reboot 也會掛 → 強制關機；引入 crash-capture 強化

## 誤判與糾正

1. **「0b 卡快壞了」**
   - 證據（看似）：0b 直通時掉卡頻繁
   - 糾正：host 每次開機**全部四張卡**都打 55×/卡 的 `NVRM: Booter failed ... 0x31`（集中在 9 秒內一批）＋一次 `SEC2_DEBUG PCIe retrain ... speed=1`，之後 `LnkSta` 恢復 `5GT/s x16` → 驅動/韌體組合的**正常開機噪音**
   - 再驗證：用戶自己把直通從 0b 換成 44，照樣掉 → **系統性問題**（任何 CMP 170HX + 滿載），非單卡
2. **「DSH renderer 崩潰是 app bug」**
   - 糾正：崩潰與 GPU 路徑相關（掉卡前後），加 `--disable-gpu` 後消失 → 下游症狀，非 app 本身
3. **「`gsp-restore show` 出現 `bsi_secure_scratch_14 = 0x00100000 (needs restore)` ＝ 卡又被鎖死、要跑 restore」**
   - 證據（看似）：keepalive 每 2 分鐘都報「cannot clear bsi_secure_scratch_14 - write protected once set」
   - 糾正：這個值是**已解鎖 CMP 卡的常態**（host 自己的 0a/0b/43 也回同值且正常運作），**掉電重開都清不掉**、但 GPU 照樣好 → keepalive 的抱怨是**雜訊**，不是掉卡判準。真正的掉卡判準＝**卡從 VM 裝置管理員消失**
4. **「DSH 崩潰 ＝ 掉卡的症狀，GPU 好就不會崩」**
   - 糾正：DSH **自動更新**（本案例 rc.1→rc.3）會**沖掉 asar 的 `--disable-gpu` 補丁** → GPU 卡好好的，崩潰（含 host 端 `0xC0000005` access violation）仍會回來 → 每次 DSH 更新後要**重打補丁**
5. **「host 死機 ＝ GPU 直通卡的問題」**
   - 糾正：第二輪有 1-2 次 host 死機是**人為把 0b（host 卡）錯綁到 vfio** 造成 → vLLM 找不到 `/dev/dri/card2`、dockerd CDI 一直重試 → host 掛。判別：host 死機 tail 出現 `CDI ... /dev/dri/cardX: no such file` 就是綁錯卡，不是 44 直通卡不穩

## 工具/格式坑

3. **minidump 不是 MDMP**：`C:\Windows\Minidump\*.dmp` 檔頭是 **`PAGEDU64`**（kernel dump 容器），用標準 MDMP 解析器會得到 `bad sig 0x45474150`（＝"PAGE"）。→ 改用**事件日誌**：`Microsoft-Windows-WER-SystemErrorReporting` Id 1001 含完整 bugcheck 碼＋參數＋dump 路徑（見 `scripts/guest/read-bugchecks.ps1`）
4. **`virsh domstate` 受 locale 影響**：中文主機回「執行中」而非 `running` → graceful-stop 的輪詢永遠匹配不到 → `fix-gpu.sh` 必須保留 90s 後的 `virsh destroy` fallback（設計上必要，不是備而不用）
5. **cp950 UnicodeEncodeError**：PowerShell（cp950）print host 輸出的 `━`（U+2501）等字會炸 → 把 host 輸出**寫進 UTF-8 檔**再讀
6. **SSH banner 卡住**：該 VPS 的 sshd 有時 banner 慢 → 連線間隔拉到 90–120s；`banner_timeout`/`auth_timeout` 給足
7. **SFTP 寫 root 目錄被拒**：sftp 以普通用戶身份連 → 先傳到 home 再 `sudo cp`
8. **PowerShell 受限模式**：部分環境 `1MiB` 數字後綴不可用 → 用字面量（1048576）
9. **elevated 讀 minidump**：`C:\Windows\Minidump` 的 ACL 限制 → 解析要 `Start-Process -Verb RunAs`（本案例 VM 的本地管理員 UAC `ConsentPromptBehaviorAdmin=0`，可靜默提升）
10. **sed 改 GRUB 的引號地獄**（PowerShell here-string → ssh → remote bash 三層引號）：`sed -i "s/…\"…/"` 與 `sed 's|…=""|…="…"|'` 都會被啃掉引號（結果 `GRUB_CMDLINE_LINUX=crashkernel=256M"`，grub-mkconfig 報 `EOF in backquote substitution`）；用 `\042` 更糟——sed **替換段**的 `\0` 是「整行匹配反向引用」，`\042` ＝ 整行＋"42"，那行直接翻倍變形。→ **用 base64 編碼的 python3 重寫該行**（`echo $b64 | base64 -d | sudo python3 -`），或把腳本 scp 上 host 再執行（見 `scripts/host/install-crash-capture.sh` 的寫法）
11. **kdump 的 unit 名是 `kdump-tools`**，不是 `kdump`（`systemctl enable kdump` → "Unit kdump.service does not exist"）；`kdump-config prepare` 不是有效子命令（有效：`test|show|status|load|unload|savecore|…`）
12. **`dsh-disable-gpu.mjs` 的通用回退在 rc.3 失效**：回退只掃 asar 前 64 MiB，而 rc.3 的 `lib/main.js` 在 ~201 MiB 處 → 用專用的 `dsh-disable-gpu-rc3.mjs`（錨點＝main.js 中 `/** IPC channel names kept private to the desktop application bundle. */` 那行單行 JSDoc）。rc.3 main.js 是 **ESM bundle**（頂部 `import … from "electron"`）→ 補丁注入的 `app.commandLine.appendSwitch("disable-gpu");` 必須落在**模組 body 的 top-level**（import 之後、`app.whenReady` 之前），執行時機才夠早

## 此平台 N/A 的「常見解法」（不要浪費時間）

10. `nvidia-smi -pm 1`（persistence mode）→ "not supported for GPU ... on this platform"（GA100 直通平台限制）
11. `powercfg` 關 PCIe Link State PM → Win11 24H2 的電源計畫**已移除** PCI Express 子群組該設定；且此卡不支援 ASPM
12. NvDLIS `18022=1`（偏好最大效能）→ 寫得進去，但 datacenter 驅動疑似不套用（idle 時脈仍 210 MHz）→ 可寫、別指望

## 有效的解法（按貢獻排序）

13. **GSP keepalive（host, systemd timer, 2min）**：軟掉卡自動 re-arm；自動偵測 vfio-pci 卡（換卡不用改）；VM 不用時零影響。**上線當晚即自動救回一次 44 卡**
14. **fix-gpu.sh 完整救援**：含 ACR stuck state 處理（passthrough.sh restore 會 rmmod 保護模組 → reset → 重綁 → 重新 arm）
15. **DSH `--disable-gpu`**（同長度 in-place asar 補丁，保留 asar hash）：renderer 崩潰消失
16. **TdrDelay=60**（guest, `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`）：把 TDR 重置延遲從 2s 拉到 60s，減少短暫卡頓被 TDR 放大成驅動錯誤
17. **DSH 補丁重打（每次 app 更新後）**：`node scripts/guest/dsh-disable-gpu-rc3.mjs`（rc.3 錨點、備份 `app.asar.bak-disable-gpu-<date>`、同長度原位）。驗證三聯：renderer 進程參數含 `--disable-gpu` ＋ gpu-process 參數 `--use-angle=d3d11-warp-webgl`（**WARP＝軟體**）＋ `nvidia-smi --query-compute-apps` 無 DSH 進程。本案例 rc.3 補丁上線後 7+ 小時零崩潰
18. **host crash-capture 強化**（`scripts/host/install-crash-capture.sh`）：rasdaemon（MCE/PCIe AER）＋ `softlockup_panic=1`/`hung_task_panic=1`（立即）＋ kdump-tools＋GRUB `crashkernel=256M`（下次開機後 vmcore 生效）。強化前 host 硬掛死**零證據**（兩次都查不出死因），強化後：hang→panic→堆疊進 journal，MCE 進 rasdaemon，開機後 vmcore 落 `/var/crash`

## Host 硬掛死（與「掉卡」不同維度，2026-11-14/15 實測）

- **簽名**：host **靜默硬掛死**——journal 戛然而止，死前**無 kernel panic／Xid／soft lockup**；最後幾行全是 userland（11/14 03:18：dockerd CDI `/dev/dri/card2` 錯誤循環；11/15 04:32：tailscale `network is unreachable` 風暴）→ 通常「網絡先死、數秒後全機死」
- **VM 死前還活著**（DHCP 續約記錄）且下次開機無藍屏 → **host 先死、連累 VM**（不是反過來）
- **嫌疑層**：host 端 3 張 CMP 卡＋nvidia 驅動（615.71.09）——不是 VM 直通卡、不是 DSH、（本輪）也不是綁錯卡
- **host 的正常 `reboot` 也會掛**（nvidia 驅動狀態不乾淨）→ **強制關機（掉電）才可靠**；掉電同時清掉所有 stuck 狀態，是最終手段
- **自傷變體**：把 host 卡（0a/0b/43）錯綁 vfio → 該卡 `/dev/dri/cardX` 消失 → vLLM 容器 CDI 注入失敗、dockerd 錯誤循環 → host 掛（與上面的 CDI 簽名相同，先查最近動過哪張卡）
- **noise 對照（別當死因）**：①kernel 7.0.0-43 的 UBSAN `shmem_show_options` out-of-bounds `Call Trace`＝**非致命**（systemd 讀 /proc/mountinfo 觸發），系統照常跑數小時；②libvirtd 偶爾「unclean termination」＋自動重啟（同一不穩定的可能早期徵兆，記錄即可）
- **處置**：①掉電重開（VM 隨 host 自啟，直通卡在 rebind 時自動還原 GSP）②查 crash-capture 證據（`ras-mc-ctl --errors`、`/var/crash`、`journalctl -b -1` 的 lockup/panic/Call Trace）③反覆出現 → 升 host nvidia 驅動／kernel、或停用 host 閒置卡做隔離測試

## 藍屏代碼對照（本案例實際出現）

| Bugcheck | 次數 | 意義 |
|---|---|---|
| `0x1A` MEMORY_MANAGEMENT | 多次（subcode 0x9696/0x411/0x41792） | 記憶體結構被糟蹋（GPU DMA 層線索） |
| `0x139` DPC_WATCHDOG_VIOLATION | 1 | GPU 驅動 DPC 卡死（GPU 沒回應） |
| `0x7E` SYSTEM_SERVICE_EXCEPTION | 1 | 驅動 access violation（`0xC0000005`） |

→ 三者合起來＝**滿載下 GPU 驅動/顯存層不穩**（硬體/韌體層），TDR 擋不住；靠救援層快速恢復＋（必要時）減負/換卡。

## 隱私紅線（本 repo 的約束）

- 不放：IP 位址、SSH 密碼、GitHub token、特定主機名、Windows 使用者名稱
- 所有環境值以佔位符/預設參數呈現；複用時自行取代
