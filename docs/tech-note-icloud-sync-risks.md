# Tech Note: Rủi ro khi đồng bộ OAuth credentials qua iCloud Drive

**Dự án:** Claude Swap Widget  
**Ngày:** 2026-05-21  
**Phạm vi:** Cơ chế cloud sync — đọc/ghi bundle mã hoá trên iCloud Drive

---

## Bối cảnh

Claude Swap Widget cho phép người dùng lưu nhiều tài khoản Claude và chuyển đổi nhanh giữa chúng trên macOS. Để hỗ trợ sử dụng trên nhiều máy Mac, widget mã hoá toàn bộ thông tin đăng nhập thành một file bundle (AES-256-GCM) rồi đặt vào thư mục iCloud Drive. macOS tự động đồng bộ file này giữa các máy — không cần server trung gian, không cần tài khoản thứ ba.

Đây là một thiết kế **zero-server**: mọi thứ di chuyển qua iCloud của chính người dùng, được mã hoá bằng passphrase chỉ người dùng biết.

---

## Cấu trúc dữ liệu

Mỗi tài khoản Claude sử dụng **OAuth 2.0** với hai token:

| Token | Vai trò | Vòng đời |
|-------|---------|----------|
| Access Token | Gọi API thực tế | Ngắn (vài giờ) |
| Refresh Token | Lấy access token mới | Dài (tháng/năm), có thể bị thu hồi |

Widget lưu cả hai token trong macOS Keychain theo hai slot:
- **Live slot**: token của tài khoản đang hoạt động — Claude Code đọc trực tiếp từ đây.
- **Backup slot** (per-account): bản sao của mọi tài khoản — widget dùng để switch và đọc usage.

Bundle iCloud là **snapshot** của tất cả backup slots tại thời điểm push.

---

## Các rủi ro đã xác định

### R1 — Token mới pull về không được kiểm tra ngay

**Vấn đề:** Sau khi pull bundle từ iCloud, các token được ghi vào Keychain nhưng không ai kiểm tra chúng có còn hợp lệ không. Nếu token trong bundle đã bị thu hồi (người dùng đổi mật khẩu, revoke session...), lỗi chỉ xuất hiện lúc người dùng thực sự chuyển sang tài khoản đó — trải nghiệm tệ.

**Hậu quả:** Người dùng tưởng sync thành công, nhưng tài khoản thực ra không dùng được cho đến khi switch và thấy lỗi.

---

### R2 — Tài khoản đang hoạt động bị bỏ sót khỏi bundle

**Vấn đề:** Khi push bundle, widget đọc token của tài khoản đang hoạt động từ live Keychain slot. Nếu đọc thất bại (Keychain bị khoá, quyền truy cập bị từ chối...), code cũ **im lặng bỏ qua** tài khoản đó và tiếp tục push bundle thiếu.

**Hậu quả:** Máy Mac khác pull bundle này sẽ không có tài khoản đang hoạt động. Người dùng mất tài khoản trên máy mới mà không có cảnh báo nào.

---

### R4 — Bundle không được cập nhật sau khi switch tài khoản

**Vấn đề:** Mỗi lần switch tài khoản, widget lưu snapshot credential của tài khoản vừa rời vào backup slot. Nhưng không có bước nào push bundle lên iCloud sau đó.

**Hậu quả:** Máy khác pull sau một lần switch sẽ nhận được bundle cũ — thiếu snapshot mới nhất. Dần dần, bundle trở nên stale so với trạng thái thực trên máy gốc.

---

### R5 — Race condition giữa push và switch

**Vấn đề:** `CloudPush` và `SwitchAccount` đều đọc/ghi Keychain và config file, nhưng không có cơ chế loại trừ lẫn nhau (mutual exclusion). Nếu hai thao tác xảy ra đồng thời — ví dụ push được trigger tự động trong lúc người dùng đang switch — bundle có thể ghi lại trạng thái nửa chừng.

**Hậu quả:** Bundle phản ánh trạng thái không nhất quán: có thể có credential của tài khoản đích nhưng config chưa cập nhật, hoặc ngược lại.

---

### Option A — Pull ghi đè credential mới hơn ở local

**Vấn đề:** Pull bundle luôn ghi đè backup slot của mỗi tài khoản bằng nội dung từ bundle, bất kể token nào mới hơn. Tình huống nguy hiểm: máy A vừa refresh token (token mới), máy B push bundle (token cũ). Nếu máy A pull ngay sau đó, token mới trên máy A bị ghi đè bằng token cũ từ máy B.

**Hậu quả:** Tài khoản trên máy A phải đăng nhập lại dù chưa có gì sai — mất công không cần thiết và gây nhầm lẫn.

---

### Option B — Bundle chứa token inactive đã cũ

**Vấn đề:** Push bundle đọc token inactive từ backup slots mà không làm mới chúng trước. Token trong Keychain có thể đã vài ngày, vài tuần tuổi — đặc biệt với refresh token có thể đã hết hạn hoặc bị provider thu hồi do bảo mật.

**Hậu quả:** Bundle mang token cũ sang máy khác. Máy mới pull về và dùng token đó → refresh thất bại → tài khoản cần đăng nhập lại ngay lần đầu switch.

---

### R6 — Một lỗi ghi Keychain huỷ toàn bộ quá trình restore

**Vấn đề:** Khi pull, nếu việc ghi credential của một tài khoản thất bại (ví dụ slot Keychain bị khoá cho tài khoản đó), toàn bộ vòng lặp dừng lại. Registry (danh sách tài khoản) không được lưu, kể cả cho những tài khoản đã ghi thành công.

**Hậu quả:** Người dùng có 4 tài khoản, tài khoản số 2 lỗi Keychain → cả 4 đều không được restore. Trải nghiệm: pull thành công (không có lỗi rõ ràng) nhưng widget không thấy tài khoản nào.

---

## Tổng hợp mức độ

| Rủi ro | Khả năng xảy ra | Hậu quả | Mức độ |
|--------|----------------|---------|--------|
| R2 — Active account bị bỏ sót | Thấp (Keychain hiếm khi lỗi) | Mất tài khoản không cảnh báo | **Cao** |
| R5 — Race push/switch | Thấp–Trung (auto-push + user action) | Corrupt state | **Cao** |
| Option A — Ghi đè token mới hơn | Trung (multi-Mac active) | Mất credential, phải login lại | **Cao** |
| Option B — Bundle chứa token cũ | Cao (token inactive ít được làm mới) | Login lại trên máy mới | Trung |
| R6 — Một lỗi huỷ toàn bộ restore | Thấp | Restore không hiệu quả | Trung |
| R1 — Token pull về không validate | Cao (silent, không ai biết) | Lỗi muộn khi switch | Trung |
| R4 — Bundle stale sau switch | Cao (mọi lần switch) | Máy khác nhận bundle cũ | Thấp |

---

## Giải pháp kỹ thuật

### Phase 1 — Hardening phía Push (`cloud_push.go`)

**Option B — Làm mới token trước khi đóng gói**

Trước khi push, gọi `RefreshAllTokens` để làm mới tất cả token inactive. Bước này chạy **trước** khi acquire file lock vì có thể gọi network — không muốn network I/O chạy trong khi giữ lock.

```
CloudPush:
  1. RefreshAllTokens()          ← mới, không giữ lock
  2. Lock.Acquire()              ← mới (R5)
  3. Registry.Load()
  4. Đọc credentials → đóng gói bundle
  5. Encrypt → WriteFile
  defer Lock.Release()
```

**R5 — Thêm file lock**

`CloudPush` và `SwitchAccount` dùng cùng một `FileLock`. `SwitchAccount` đã acquire lock ở bước đầu. `CloudPush` nay cũng acquire trước khi đọc Keychain — hai thao tác không thể chạy đồng thời.

**R2 — Fallback cho active account**

Thay vì `continue` khi không đọc được live Keychain:
```
Trước: live read fail → bỏ qua → bundle thiếu active account (silent)
Sau:   live read fail → đọc backup → backup cũng trống → return error (explicit)
```
Bundle chỉ được push khi chắc chắn có đủ credential của tài khoản đang hoạt động, hoặc trả về lỗi rõ ràng.

---

### Phase 2 — Hardening phía Pull (`cloud_pull.go`)

**Option A — Chọn token mới hơn**

Với mỗi tài khoản trong bundle, so sánh `expiresAt` của token trong bundle với token đang có ở local. Ghi token nào có `expiresAt` cao hơn.

```
Quy tắc:
  local.expiresAt > bundle.expiresAt  → giữ local (local mới hơn)
  local.expiresAt ≤ bundle.expiresAt  → ghi bundle (bundle mới hơn, hoặc bằng → bundle thắng)
  local không tồn tại                  → ghi bundle (máy mới, không có gì để so)
  parse lỗi (bất kỳ bên nào)          → ghi bundle (safe fallback)
```

`expiresAt = 0` được xử lý như epoch — luôn thua một token thực.

**R6 — Partial failure**

Thay vì return error khi một tài khoản lỗi:
```
Trước: lỗi tài khoản N → return error → registry không được lưu cho N-1, N+1...
Sau:   lỗi tài khoản N → ghi vào failures[] → tiếp tục N+1...
       Cuối vòng lặp: Registry.Save() cho tất cả tài khoản thành công
       Return partial-error nếu có failures
```
Người dùng nhận được thông báo rõ: "restored 3/4 accounts: account 2 (user@email.com): keychain error".

**R1 — Validate ngay sau pull**

Sau khi `Registry.Save` thành công, spawn goroutine background gọi `RefreshAllTokens` (timeout 30s). Token nào không còn hợp lệ sẽ được phát hiện ngay và đánh dấu `needs_login` — thay vì chờ đến lần switch.

```
CloudPull:
  ...
  Registry.Save()
  go RefreshAllTokens()   ← background, không block
  return (partial error nếu có)
```

---

### Phase 3 — Auto-push sau switch (`AppStore.swift`)

**R4 — Gọi `autoPushCloud` sau mỗi switch thành công**

```swift
// Trước
schedulePostSwapIntegrations()

// Sau  
schedulePostSwapIntegrations()
await autoPushCloud()   // non-blocking: chạy detached background task
```

`autoPushCloud` đã có guard kiểm tra passphrase — nếu chưa cấu hình cloud sync thì là no-op, không hiển thị lỗi cho người dùng.

---

## Invariant quan trọng

> **`RefreshAllTokens` không được acquire `FileLock`.**  
> Trong `CloudPull`, background goroutine R1 được spawn trong khi `defer Lock.Release()` vẫn còn active. Nếu `RefreshAllTokens` gọi `Lock.Acquire`, sẽ xảy ra deadlock. Điều này được document bằng comment INVARIANT trong code.

---

## Retry policy cho backup token refresh

### Vấn đề trong bản triển khai đầu tiên

`backupTokenRefreshIfNeeded()` ghi timestamp `lastBackupTokenRefreshAt` **trước** khi RPC hoàn thành. Đây là thay đổi có chủ đích so với code cũ (vốn chỉ ghi sau khi success) — mục tiêu là throttle cả những lần gọi thất bại để tránh hammer Anthropic khi grant bị thu hồi liên tục.

Tuy nhiên, policy này **không phân biệt loại lỗi**:

| Loại lỗi | Retry sau 6h có hợp lý? |
|----------|------------------------|
| `invalid_grant` — refresh token bị thu hồi | ✓ Đúng — retry sớm không có ích |
| Network timeout, subprocess fail, backend unavailable | ✗ Sai — 6h là quá dài cho transient error |

Hậu quả: một transient failure lúc startup (network chưa ổn định) sẽ suppress mọi backup refresh trong 6h kế tiếp — backup tokens có thể expire trong khoảng đó mà không ai làm mới.

### Giải pháp: tách hai timestamp với hai policy

```
lastBackupTokenRefreshAt        → ghi TRƯỚC RPC — throttle attempt spam (6h)
lastBackupTokenRefreshSuccessAt → ghi SAU RPC success — track freshness thực sự
```

**Logic retry:**

```
timeSinceAttempt = now - lastBackupTokenRefreshAt
timeSinceSuccess = now - lastBackupTokenRefreshSuccessAt
lastAttemptFailed = timeSinceSuccess > timeSinceAttempt + 60s

shouldRetry = timeSinceAttempt ≥ 6h                          // normal cycle
           OR (lastAttemptFailed AND timeSinceAttempt ≥ 15min) // transient retry
```

- Persistent failure (`invalid_grant`): mỗi lần fail, attempt timestamp được cập nhật → retry sau 15min tiếp theo → retry lại nhiều lần nhưng success timestamp vẫn cũ → eventually người dùng thấy tài khoản `needs_login`. Không spam mỗi poll interval.
- Transient failure (network): retry sau 15min, khi thành công ghi success timestamp → quay lại cycle 6h bình thường.
- Normal success: attempt và success được ghi cùng lúc → `lastAttemptFailed = false` → chỉ retry sau 6h.

---

## Những gì chưa được xử lý

- **MCP connector failures vẫn hard-fail toàn bộ loop**: lỗi khi restore MCP secret của tài khoản N vẫn dừng toàn bộ quá trình restore. Scope của R6 chỉ áp dụng cho credential failures, không cho MCP secrets.
- **Shared MCP connectors được lưu kể cả khi credential restore hoàn toàn thất bại**: đây là pre-existing behavior, low risk vì MCP metadata và credentials dùng Keychain slot khác nhau.
