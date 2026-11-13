# 踩坑記錄（Pitfall Log）

本案例（2026-11，4× CMP 170HX，Ubuntu host + Win11 VM）的完整踩坑史。按主題整理，供複用時避坑。

## 時間軸（摘要）

- 症狀開始：直通卡（先 0b 後 44）在 ComfyUI 滿載後反覆掉卡；VM 反覆藍屏；DSH renderer 崩潰
- 診斷期：誤判「0b 卡快壞」→ 被 host 開機日誌否定（Booter 0x31 四卡都有）
- 處置期：DSH `--disable-gpu` 補丁 → guest 端 TDR/電源設定（方案 2）→ 換卡 0b→44 → host GSP keepalive（方案 3）
- 結果：不再掉卡

## 誤判與糾正

1. **「0b 卡快壞了」**
   - 證據（看似）：0b 直通時掉卡頻繁
   - 糾正：host 每次開機**全部四張卡**都打 55×/卡 的 `NVRM: Booter failed ... 0x31`（集中在 9 秒內一批）＋一次 `SEC2_DEBUG PCIe retrain ... speed=1`，之後 `LnkSta` 恢復 `5GT/s x16` → 驅動/韌體組合的**正常開機噪音**
   - 再驗證：用戶自己把直通從 0b 換成 44，照樣掉 → **系統性問題**（任何 CMP 170HX + 滿載），非單卡
2. **「DSH renderer 崩潰是 app bug」**
   - 糾正：崩潰與 GPU 路徑相關（掉卡前後），加 `--disable-gpu` 後消失 → 下游症狀，非 app 本身

## 工具/格式坑

3. **minidump 不是 MDMP**：`C:\Windows\Minidump\*.dmp` 檔頭是 **`PAGEDU64`**（kernel dump 容器），用標準 MDMP 解析器會得到 `bad sig 0x45474150`（＝"PAGE"）。→ 改用**事件日誌**：`Microsoft-Windows-WER-SystemErrorReporting` Id 1001 含完整 bugcheck 碼＋參數＋dump 路徑（見 `scripts/guest/read-bugchecks.ps1`）
4. **`virsh domstate` 受 locale 影響**：中文主機回「執行中」而非 `running` → graceful-stop 的輪詢永遠匹配不到 → `fix-gpu.sh` 必須保留 90s 後的 `virsh destroy` fallback（設計上必要，不是備而不用）
5. **cp950 UnicodeEncodeError**：PowerShell（cp950）print host 輸出的 `━`（U+2501）等字會炸 → 把 host 輸出**寫進 UTF-8 檔**再讀
6. **SSH banner 卡住**：該 VPS 的 sshd 有時 banner 慢 → 連線間隔拉到 90–120s；`banner_timeout`/`auth_timeout` 給足
7. **SFTP 寫 root 目錄被拒**：sftp 以普通用戶身份連 → 先傳到 home 再 `sudo cp`
8. **PowerShell 受限模式**：部分環境 `1MiB` 數字後綴不可用 → 用字面量（1048576）
9. **elevated 讀 minidump**：`C:\Windows\Minidump` 的 ACL 限制 → 解析要 `Start-Process -Verb RunAs`（本案例 VM 的本地管理員 UAC `ConsentPromptBehaviorAdmin=0`，可靜默提升）

## 此平台 N/A 的「常見解法」（不要浪費時間）

10. `nvidia-smi -pm 1`（persistence mode）→ "not supported for GPU ... on this platform"（GA100 直通平台限制）
11. `powercfg` 關 PCIe Link State PM → Win11 24H2 的電源計畫**已移除** PCI Express 子群組該設定；且此卡不支援 ASPM
12. NvDLIS `18022=1`（偏好最大效能）→ 寫得進去，但 datacenter 驅動疑似不套用（idle 時脈仍 210 MHz）→ 可寫、別指望

## 有效的解法（按貢獻排序）

13. **GSP keepalive（host, systemd timer, 2min）**：軟掉卡自動 re-arm；自動偵測 vfio-pci 卡（換卡不用改）；VM 不用時零影響。**上線當晚即自動救回一次 44 卡**
14. **fix-gpu.sh 完整救援**：含 ACR stuck state 處理（passthrough.sh restore 會 rmmod 保護模組 → reset → 重綁 → 重新 arm）
15. **DSH `--disable-gpu`**（同長度 in-place asar 補丁，保留 asar hash）：renderer 崩潰消失
16. **TdrDelay=60**（guest, `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`）：把 TDR 重置延遲從 2s 拉到 60s，減少短暫卡頓被 TDR 放大成驅動錯誤

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
