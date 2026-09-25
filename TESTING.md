# Junction Manager — vận hành, an toàn và kiểm thử

```text
Junction Manager
Version: V1.0.0
Author: Nemoforge (DINH DUC LOC)
Support: nemoforge.github.io | support@studyhelp.space
```

Metadata trong code có một nguồn duy nhất: `$script:AppInfo` ở `Junction.ps1`. Title, footer hai dòng và một dòng startup log lấy từ cấu trúc này. Footer có link HTTPS và mailto; lỗi shell association được báo ở status, không đóng ứng dụng. Không kiểm tra Internet trước khi mở link.

## Các file cần giữ cùng nhau

- `Junction.ps1`: migration engine hiện có, WPF, runspace nền và điều phối UI.
- `Junction.Discovery.ps1`: Discovery chỉ đọc; registry, process, metadata, ranking và candidate size.
- `Junction.Maintenance.ps1`: provenance, managed logs và Delete Backup.
- `Junction.Update.ps1`: JSON/HTTPS validation, manual update check và About UI.
- `script.bat`: launcher hiện có, không thay đổi trong lần nâng cấp này.

Chạy `script.bat` hoặc:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".\Junction.ps1"
```

PS1 tự yêu cầu UAC/chuyển Windows PowerShell Desktop STA khi cần. Ba file logic đi kèm phải ở cùng thư mục PS1. Không có C#, EXE, installer hoặc dependency bên ngoài.

Gói nguồn giữ documentation và thư mục `tests`, không kèm `.test-sandbox` hoặc `MigrationLogs`. Hai thư mục runtime/test này được loại khỏi Git bằng `.gitignore`. Ứng dụng tự tạo log root, ownership marker và session an toàn lúc khởi động; không cần ship marker được tạo từ máy phát triển. Khi đóng gói từ workspace đã chạy ứng dụng, bỏ runtime logs khỏi gói; giữ riêng journal còn cần cho recovery.

## Discovery

Tab **App Discovery** có tìm theo tên app/process/EXE, Installed Apps, Scan Locations, bảng candidate, Use as Source và Calculate Selected Size. Double-click candidate cũng chọn Source. Candidate file được chuyển thành parent directory; candidate directory dùng chính nó. Chọn candidate luôn vô hiệu hóa Analyze cũ và không chạy Move.

Discovery đọc HKLM Uninstall ở registry view 64/32 bit và HKCU Uninstall; không chạy UninstallString/DisplayIcon. Registry key được mở với `writable = false`. Process chỉ được inspect, không bị stop. FileVersionInfo được đọc, executable không được chạy.

Tên EXE lạ được nối với process, ProductName/FileDescription/CompanyName, hai thư mục cha và metadata registry để suy ra các token liên quan. Token generic như bin/cache/updater không được dùng độc lập làm identity. Mỗi path chỉ có một result; Reason được gộp khi có nhiều signals. Running executable có ưu tiên cao nhất, sau đó registry, exact/product/folder, prefix và weak contains. “Main executable candidate” và classification chỉ là gợi ý; Analyze vẫn quyết định điều kiện migration.

Các root được suy ra từ Known Folder APIs: Program Files, Program Files x86, LocalAppData Programs, LocalAppData, Roaming, System32, SysWOW64 và WindowsApps. Root không trùng lặp; root cụ thể như LocalAppData Programs được phân loại Install thay vì Data. System roots chỉ kiểm tra tên EXE cụ thể, không liệt kê toàn bộ executable làm candidate. WindowsApps bị từ chối quyền đọc chỉ tạo warning; không đổi ACL/ownership. Analyze chặn Windows/WindowsApps.

Giới hạn mặc định: 15 giây, tối đa 30 giây; 20.000 entries, 1.500 directory enumerations, 3 mức thư mục con và 250 candidate. Không recursive toàn ổ; không đi xuyên reparse point. Tìm sâu chỉ thực hiện với seed đã match hoặc token đủ cụ thể. Cancel được kiểm tra giữa các lần enumerate/query. Một lời gọi OS đang chờ I/O không thể bị hủy ngay lập tức.

Size của directory mặc định Unknown; chỉ tính candidate được chọn trong worker, tối đa 5 giây với cùng giới hạn entry. Không tính recursive toàn scan root hoặc Windows root. Size là dung lượng logic của file chính, không phải allocated size/ADS đầy đủ; failure/partial/cancel trả Unknown. Source size trong Analyze vẫn dùng inventory đầy đủ gồm ADS như trước.

**Trong lúc Discovery không ghi file, kể cả log:** thông báo realtime nằm trong UI/memory. Session log được khởi tạo khi mở ứng dụng, trước Discovery. Đây là lựa chọn để ưu tiên yêu cầu read-only tuyệt đối; không có discovery log mới trên đĩa để cleanup.

## Migration và rollback

Luồng giữ nguyên: validate → xác nhận → xử lý process có đồng ý → validate lại → robocopy → inventory → FinalSync → robocopy `/L` → inventory → rename thành backup → SHA-256/ADS → junction → verify → commit.

Code production giữ `/COPYALL /DCOPY:DAT /SECFIX /TIMFIX /XJ /SL`, retry hữu hạn, không dùng `/MIR`, `/PURGE`, `/MOVE` hoặc `/MOV`. Exit 0–7 không bị coi là lỗi copy nghiêm trọng; pass verification `/L` phải trả 0. [Tài liệu robocopy của Microsoft](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy).

Backup không tự xóa. Source tạm thời không truy cập được trong giai đoạn hash sau rename; giữ app/updater/service đóng đến khi hoàn tất. Quét executable không phát hiện được mọi writer/lock. Progress là indeterminate theo giai đoạn, không đưa phần trăm giả.

Rollback gỡ đúng junction bằng `Directory.Delete(path, false)` sau khi kiểm tra destination, rồi rename backup về Source; không traverse/xóa Target. Dữ liệu mới tại Target không được merge vào backup cũ. Khi Source thiếu nhưng backup còn, Browse Source có thể chọn backup để điền path gốc, rồi Analyze/Rollback.

Chỉ bổ sung hai điểm cho migration: lưu NTFS directory identity vào journal trước commit để chứng minh backup; chặn rollback khi journal cho biết backup đã bị xóa một phần. Không lấy được identity không làm mất migration đã verify, nhưng Delete Backup sẽ bị vô hiệu hóa.

## Managed logs / Clear Logs

Log root vẫn là `MigrationLogs` cạnh script; fallback là `%LOCALAPPDATA%\JunctionUtility\Logs`, rồi `%TEMP%\JunctionUtility\Logs`. Mỗi root mới/được khởi tạo có `.junction-log-root.json`; mỗi session mới có `.junction-log-session.json` gắn RootId/SessionId và canonical path.

Clear Logs chỉ xử lý root đang được ứng dụng sử dụng, kiểm tra nó thuộc danh sách root chính thức, không phải root/system/profile container, không overlap Source/Target/Backup và không có reparse ancestor. Không nhận arbitrary directory từ UI.

Chỉ session có marker đúng và chỉ chứa file log được nhận diện mới được xét xóa. UI báo số session/file và approximate size rồi yêu cầu xác nhận. Các trường hợp sau được giữ nguyên:

- Session hiện tại.
- Journal pending, không parse được, identity không khớp hoặc trạng thái recovery chưa resolved.
- Journal của migration còn backup, kể cả Committed, để giữ provenance/recovery.
- Session/file legacy không có marker, unknown files/subfolders hoặc reparse points.

Việc xóa kiểm tra lại ownership/state sau confirmation, enumerate trước, xóa từng file và directory rỗng bằng thao tác không đệ quy. Marker của root bị xóa cuối cùng. File bị khóa tạo báo cáo partial cleanup với đường dẫn còn lại; không có fallback xóa mạnh tay. Open Logs mở root hiện hành.

**Log từ bản cũ không có marker sẽ không bị Clear Logs tự nhận ownership/xóa.** Các log thật sẵn có trong workspace không được dùng làm dữ liệu cho test cleanup.

## Delete Backup

Delete Backup chỉ enable sau Analyze/refresh đã chứng minh đồng thời:

- Source là Junction và destination thực tế đúng Target đang chọn; Target tồn tại và không có reparse ancestor.
- Backup là directory thật, đúng `${Source}_backup`, không overlap Source/Target/tool/logs và không thuộc system/root.
- Có session/journal do Junction Manager quản lý, transaction mới nhất cho Source là Committed và mọi path khớp.
- NTFS file ID + volume identity của Backup **và** Target khớp journal. Một thư mục mới tạo lại cùng tên bị từ chối.
- Inventory toàn backup không có reparse point con, entry không đọc được hoặc path không được hỗ trợ.

Không global-search `*_backup`. Suffix một mình không bao giờ cho phép xóa. Backup của phiên bản cũ chưa có identity/journal được quản lý sẽ không có nút xóa; vẫn có thể rollback theo điều kiện cũ.

Confirmation có Source Junction, Target, exact Backup, approximate size, cảnh báo mất normal rollback và nút **Delete Backup** riêng. Sau confirmation, tool kiểm tra lại identity, junction, inventory và process chạy từ backup. Không merge hoặc ghi Target. Không bắt buộc hash lại backup và Target lúc xóa vì Target có thể đã có dữ liệu mới hợp lệ; đây là kiểm chứng identity và scope, không phải so sánh hai bản dữ liệu hiện tại.

Journal được flush với `BackupDeletePending` trước lần xóa đầu tiên; hoàn tất mới ghi `BackupDeleted`. Nếu file khóa hoặc lỗi giữa chừng, journal được giữ và rollback từ backup thiếu dữ liệu bị chặn. UI không có “resume delete” tự động cho tình huống này; cần xem journal và xử lý có chủ đích.

[Microsoft fsutil file queryfileid](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-file) được dùng để đọc NTFS identity; không dùng timestamp hoặc suffix làm bằng chứng duy nhất.

Mọi tác vụ chia sẻ một worker; Clear Logs/Delete Backup bị disable khi bận. Engine còn kiểm tra ActiveOperation để từ chối maintenance trong Move/Rollback. Sau Move/Rollback/Delete Backup/Clear Logs, UI refresh trạng thái, kể cả khi thao tác thất bại.

## Sandbox test bắt buộc

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Smoke.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Features.ps1"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".\tests\Updates.ps1"
```

Các harness chỉ tạo dữ liệu trong `<ProjectRoot>\.test-sandbox\<SessionGUID>`. `tests/Sandbox.ps1` tạo marker `.junction-test-sandbox` với SessionId, Project, Root, timestamp và NTFS identity. Mỗi case có tên/GUID riêng. Script/module copy phục vụ test WPF, log, journal, Source, Target, backup và ADS đều nằm trong session này.

Cleanup nằm trong `finally`, kiểm tra canonical containment, marker và root identity, inventory trước, chỉ gỡ junction trỏ trong sandbox mà không đi vào Target, từ chối reparse khác/đích ngoài sandbox. Sau đó dùng deleter không đệ quy và kiểm tra session root không còn. Marker sai/thiếu/malformed hoặc cleanup lỗi phải dừng và báo exact path. Sau khi session được xóa, canonicalize parent, kiểm tra đúng `<ProjectRoot>\.test-sandbox` và không có reparse ancestor. Chỉ xóa parent bằng `Directory.Delete(path, false)` nếu hoàn toàn rỗng, kể cả hidden/system entries. Mọi file/folder khác đều được giữ; parent cleanup thất bại chỉ báo warning kèm exact path, không có fallback đệ quy.

Regression harness giữ toàn bộ coverage trước và thêm UI checks. Để không ghi sang ổ khác, **chỉ identity volume trong harness được mô phỏng** nhằm đi qua gate khác volume; robocopy/junction/hash/rollback còn lại chạy thật trên project drive. Production không có chế độ bỏ qua volume check.

Khi không elevated, harness kiểm tra native `/COPYALL` thất bại an toàn, rồi thay flags **trong bộ nhớ của test** thành `/COPY:DAT` và bỏ `/SECFIX` cho các ca thành công. Khi elevated, nó dùng flags production. Confirmation được tự đồng ý và bước đóng process được bỏ qua **chỉ trong harness với fixture không có app đang chạy**. Các lỗi rename/create/verify/journal là fault injection.

Không dùng root C:/D:, AppData thật, Program Files hoặc backup app thật làm mutation fixture. Cross-volume test không tự động được thực hiện trong harness này; nếu bổ sung phải dùng sandbox có marker riêng ở cả hai volume và báo chính xác phạm vi.

## Kết quả thực tế của lần nâng cấp này — 2026-09-25

- Project: `E:\code\project\app`; project drive: **E:**.
- Windows PowerShell **5.1.26100.9549**, NTFS; process **không elevated**.
- Parser: 0 lỗi cho cả 3 file production và 3 file test.
- WPF: load XAML thật; worker/runspace, event handlers, Analyze completion, path invalidation, Use as Source và khóa maintenance/cancel controls được chạy không hiển thị cửa sổ.
- Regression cuối: **56/56** qua, gồm toàn bộ 52 checks cũ.
- Discovery/maintenance cuối: **49/49** qua.
- Native robocopy có exit 1/0 cho các pass thành công và 16 cho probe thiếu audit privilege; không chỉ mock exit code.
- Features: unknown EXE inference, normalization, metadata, registry/path dedup, classification, access-denied warning, cancel, mutation inventory không đổi; backup identity/destination mismatch, reparse root/child, cancel delete, Target/junction được giữ, rollback unavailable sau delete; Clear Logs giữ active/recovery/unknown logs, locked-log partial report; ownership marker sai làm cleanup dừng.
- Static audit: không catch rỗng; Discovery không chứa lệnh ghi filesystem/registry, execute discovered command hoặc kill; không recursive deletion API hoặc robocopy destructive flags. File.Delete/Directory.Delete mới chỉ nằm trong deleter được gọi sau ownership checks; junction removal cũ vẫn không đệ quy. PSScriptAnalyzer chưa có sẵn nên không chạy, không cài dependency.

Read-only trên máy thật: registry Uninstall (390 app sau dedup), process paths, FileVersionInfo của executable, 8 Known Folder roots (Program Files/x86, Local Programs, LocalAppData, Roaming, System32, SysWOW64, WindowsApps). Query Zalo tìm được **4 candidate** trong khoảng **6,6 giây**. Quyền WindowsApps không được thay đổi. Các path từ registry/process có thể nằm ngoài các root mặc định; chỉ đọc chúng khi có signal liên quan.

Không có test mutation trên ổ khác E:. C: được đọc để Discovery/metadata và thông tin hệ thống; không tạo test fixture hoặc xóa log/backup thật ở đó. Không chạy cross-volume test thật trong lượt này.

Tất cả mutation sandbox roots đã tạo trong tác vụ này, bao gồm lượt test bị dừng do thiết lập mock:

```text
E:\code\project\app\.test-sandbox\3916f4d320c04265978a2d32409c3187
E:\code\project\app\.test-sandbox\8666ef5aad5a44388bf9dbe6c62c306d
E:\code\project\app\.test-sandbox\757d22cbd4904997962c33e08548879a
E:\code\project\app\.test-sandbox\9d663b17314242818892626511cfb556
E:\code\project\app\.test-sandbox\c69c33ec4c1d42c8b76bce36c298fc17
```

**Cleanup verified: no test fixture remains.** Từng harness đã xác minh session root biến mất, kể cả lượt mock lỗi. Ở cuối lượt nâng cấp Discovery/maintenance này, parent `.test-sandbox` được kiểm tra rỗng và log lịch sử ngoài sandbox được giữ nguyên. Lượt hoàn thiện metadata/packaging tiếp theo áp dụng cleanup parent mới, được báo riêng bên dưới.

## Vòng cuối: metadata, parent cleanup và packaging — 2026-09-25

Phạm vi sửa: `Junction.ps1` (metadata/footer/title/startup log), `tests/Sandbox.ps1` (parent cleanup), hai harness (kiểm tra lỗi shell và cleanup), tài liệu này và `.gitignore` mới. `Junction.Discovery.ps1`, `Junction.Maintenance.ps1`, `script.bat` và migration engine không đổi trong vòng này.

Môi trường: `E:\code\project\app`, ổ E:, Windows PowerShell 5.1.26100.9549, không elevated. Kết quả cuối: **58/58 regression/WPF**, **54/54 Discovery/maintenance/cleanup**, tổng **112 checks**. Parser cả sáu PS1: 0 lỗi. WPF XAML, event handlers và worker chạy headless; lỗi shell association cho cả website/email đã được inject và xử lý ở status, không mở browser/mail client thật.

Cleanup mới đã kiểm tra: xóa parent rỗng, giữ hidden file, giữ sibling directory, từ chối sai parent path và reparse parent với warning có exact path, giữ nguyên ownership guards. Lượt Features đầu dừng do helper chưa hỗ trợ `-WarningVariable`; đã thêm `CmdletBinding`, chạy lại Features và Smoke đạt. `finally` đã dọn cả lượt lỗi, không còn session hoặc parent rỗng sau mỗi harness.

Tất cả sandbox roots của vòng này, theo thứ tự tạo:

```text
E:\code\project\app\.test-sandbox\fc1dbddf61cc41bbbc914a3f191d3287
E:\code\project\app\.test-sandbox\0a03208061004a998366268a871a95e1
E:\code\project\app\.test-sandbox\f855399cc92a427ab38392a075707866
E:\code\project\app\.test-sandbox\e4d34b681374445d8fbb7c0cbf58e8f7
```

Không tạo fixture hoặc ghi/xóa dữ liệu trên ổ khác E:. C: chỉ đọc metadata executable hệ thống và kiểm tra backup được journal lịch sử tham chiếu đã không còn. Không chạy cross-volume test thật, không chạy lại real-machine app scan trong vòng này. Các fixture giả lập parent cleanup đều nằm bên trong session GUID tương ứng.

Packaging cleanup đã xóa `E:\code\project\app\MigrationLogs` cùng session `20260925_171859_76fa219a394d48338e2cf2693ad465b9` sau khi kiểm tra marker, identity, journal hợp lệ ở trạng thái cuối `BackupDeleted`, backup không tồn tại và không có instance giữ application mutex. Không xóa backup, Source hoặc Target thật. Dùng deleter có ownership guard, không đệ quy; marker root được xóa cuối. Log root sẽ được tạo lại khi người dùng chạy ứng dụng.

Audit `TODO`, `FIXME`, `Write-Host`, `Test123`, `debug`: không còn occurrence trong code. `temp` chỉ thuộc discovery token/classification hoặc fallback log path; `sandbox`/GUID trong harness và tài liệu là nội dung có chủ đích. Đã rà lại mọi File.Delete/Directory.Delete/Move: production guards giữ nguyên; lời gọi delete mới chỉ xóa exact parent rỗng bằng `Directory.Delete(path, false)` sau canonical/ancestor checks. Không có catch rỗng hoặc fallback xóa mạnh tay.

Final tree được enumerate kể cả hidden/system entries, không đi xuyên reparse point và đối chiếu exact file list: `.gitignore`, ba PS1 production, `script.bat`, `TESTING.md`, ba PS1 trong `tests`. Không có `.test-sandbox`, `MigrationLogs`, junction, backup/ADS fixture, temporary log/journal/dump hoặc ADS phụ trên file nguồn.

**Cleanup verified: no test fixture remains.**

**No test/runtime artifacts remain.**

Chưa kiểm tra trực tiếp bằng mắt footer ở các mức DPI/resize hoặc shell association thành công với browser/mail client thật. Cần mở ứng dụng để thử hai link nếu muốn xác nhận association của máy. Các giới hạn elevated/cross-volume/UAC của lượt trước vẫn áp dụng như phần dưới.

## Check for Updates — 2026-09-25

Chức năng nằm ở **About → Check for Updates**, dùng worker/runspace và queue hiện có. Chỉ đọc JSON sau click; không request khi startup/mở About, không scheduler, không download release, không chạy remote code, không thay thế file. Kết quả gồm UpToDate, UpdateAvailable, Ahead, Invalid, Unavailable và NotConfigured. Check giữ nguyên LastAnalysis/Source/Target, disable nút khi bận và enable lại sau failure. Download/Release Notes chỉ mở browser sau click riêng, không offer downgrade.

Logic nằm trong `Junction.Update.ps1`: `ConvertTo-AppVersion`, `Compare-AppVersion`, `ConvertTo-TrustedUpdateUri`, `Invoke-UpdateMetadataGet`, `ConvertFrom-UpdateMetadata`, `Get-UpdateMetadata`, `Get-UpdateStatus`, `Open-TrustedUpdateUri`, `New-UpdateAboutWindow`; result/log helpers chỉ chuyển trạng thái ngắn gọn. Metadata và endpoint vẫn tập trung tại `$script:AppInfo`. Schema và publication steps nằm trong [README.md](README.md); `version.json` là metadata cần publish, không phải script.

Transport dùng HttpClient built-in: HTTPS và certificate validation bình thường, timeout 8 giây, buffer 16 KiB với ResponseContentRead, không retry/redirect/cookie/default credentials. Không gửi user/hostname/app list/path/log hoặc query string; chỉ GET public metadata. URL page phải thuộc website tác giả hoặc repository/release pages của repo này; URL raw JSON chỉ được đọc, không được mở như download page. Remote version/notes/URL được kiểm tra type/length; notes dùng TextBox read-only, không render HTML/XAML. Không thay đổi TLS hoặc certificate policy toàn process. Tham khảo [Microsoft HttpCompletionOption](https://learn.microsoft.com/en-us/dotnet/api/system.net.http.httpcompletionoption) và [AllowAutoRedirect](https://learn.microsoft.com/dotnet/api/system.net.http.httpclienthandler.allowautoredirect).

Môi trường kiểm thử: `E:\code\project\app`, E:, Windows PowerShell 5.1.26100.9549, không elevated. **58 regression/WPF + 54 Discovery/maintenance + 74 update offline = 186 checks đạt**. Parser: cả 8 PS1 không lỗi; client/handler thật được khởi tạo offline để xác nhận các property timeout/buffer/redirect/credential được hỗ trợ.

Update tests dùng fixture JSON và thay HTTP boundary trong bộ nhớ/host copy nằm trong sandbox; không phụ thuộc public Internet, không chạy browser thật. Có same/newer patch/minor/major, V1.10.0 > V1.9.9, older, malformed/root array/missing/invalid version, product mismatch, field/response length, unsafe URI/host/port/credentials/query, timeout/connection failure, plain-text notes, stale-link reset, double-click và phục hồi UI. Hash/inventory không đổi trong lượt chỉ đọc metadata fixture. Các shell association failure là fault injection.

Sandbox roots của lượt này:

```text
E:\code\project\app\.test-sandbox\64a6b642be6d44d1a5cab4750c8f9731
E:\code\project\app\.test-sandbox\eb6b62fe6e584ce09434726426543e9c
E:\code\project\app\.test-sandbox\a9ec8b12f8b346f38def6d0917e20f86
E:\code\project\app\.test-sandbox\56301bc0caa84b2ab4367b0e545035ec
```

**Cleanup verified: no test fixture remains.** Parent `.test-sandbox` không còn. Sandbox cuối dùng để chạy lại toàn bộ 74 update checks sau khi cấu hình endpoint đã xác minh; tất cả vẫn đạt và không có startup request. Không tạo cross-volume fixtures; C: chỉ đọc system executable metadata/thông tin hệ thống. `.git` là metadata repository được người dùng yêu cầu tạo, không phải test fixture. `E:\code\project\app\MigrationLogs` đã tồn tại trước lượt này, được giữ nguyên và loại khỏi Git/package bằng `.gitignore`.

Audit update code: không Invoke-Expression/iex, DownloadFile, BITS, Expand-Archive, remote script execution hoặc thêm Start-Process. Shell launch mới duy nhất mở URI HTTPS sau validation; không có command arguments. Existing migration/discovery/maintenance engine và guards giữ nguyên.

Online update endpoint tested: **yes**. Sau khi push `version.json` lên repo do người dùng chỉ định, production `Get-UpdateStatus` đã GET `https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json` thành công, trả `UpToDate` và `V1.0.0`. Sau bước xác minh mới cấu hình endpoint này trong AppInfo. Không download release, không mở browser và không ghi log/file trong online probe (`-LibraryOnly`, Context null). HTTPS/certificate validation mặc định của môi trường này hoạt động; proxy/TLS failure chỉ được kiểm tra qua failure handling, không mô phỏng server chứng chỉ sai. UI trực tiếp, browser thành công và các manual tests bên dưới vẫn chưa được xác nhận.

## Chưa runtime-test và manual test còn cần

1. UAC/relaunch tương tác, Cancel UAC, native folder picker và giao diện nhìn thấy được (resize, scroll, focus, double-click), hộp Delete Backup với nút riêng.
2. Elevated `/COPYALL` cùng ACL/owner/SACL trên owned sandbox; production flags không bị hạ nhưng quyền audit chưa có trong phiên này. Cross-volume copy thật nếu cần chứng minh riêng việc đổi volume.
3. Process graceful close/force consent với app thử nghiệm trong sandbox; không terminate process thật trong test tự động.
4. Ngắt process/mất điện/tháo test volume trong VM và recovery sau restart; các lỗi transaction hiện được mô phỏng có kiểm soát.
5. Discovery trên bộ app thực tế khác, MSIX bị hạn chế quyền đọc, scan rất lớn và cancel trong lúc OS đang chờ I/O.
6. Maintenance qua UI với owned synthetic sessions/backups: confirm/cancel, refresh nút Rollback/Delete Backup, session lock và fallback log root. Không dùng dữ liệu app thật để thử chức năng xóa lần đầu.

## Giới hạn

- Không phải VSS snapshot hoặc kernel transaction. Dừng app/updater/service khi migrate; executable-path scan không biết mọi lock/writer. Không đảm bảo chống tiến trình khác cố tình thay cây thư mục giữa các bước kiểm tra; các thao tác lỗi đều dừng và giữ recovery information.
- Chỉ migration giữa hai local fixed NTFS volume khác nhau. Reparse ancestor/con, UNC/removable/SUBST, Windows/WindowsApps, EFS/offline bị từ chối. Path đầy đủ gồm projected Target/backup giới hạn 240 ký tự; tên có `~` bị từ chối để tránh alias 8.3.
- Inventory/hash tốn thời gian và RAM theo số entry. Hash xác minh file chính và ADS, không bảo đảm clone mọi NTFS metadata/hard-link relationship/directory stream/sparse layout.
- Discovery có giới hạn nên có thể bỏ sót executable sâu, installer không ghi metadata hoặc tên quá chung; metadata/publisher không phải chứng nhận identity app. Một lời gọi OS chậm có thể vượt thời gian dự kiến trước khi cancellation được xử lý.
- Legacy/unowned log sessions và backup thiếu committed identity được giữ; Clear Logs ưu tiên recovery hơn xóa hết. Đổi nơi đặt script/log root có thể khiến history cũ không còn được tìm thấy và Delete Backup bị disable.
- Delete Backup là xóa vĩnh viễn bản trước migration; không có undo/recycle bin. Partial deletion cần kiểm tra thủ công. Rollback không merge dữ liệu mới ở Target.
- Journal append-only được flush nhưng có thể có dòng cuối chưa đầy đủ khi mất điện. Journal corrupt làm maintenance từ chối xóa; không tự sửa/đoán ownership.
