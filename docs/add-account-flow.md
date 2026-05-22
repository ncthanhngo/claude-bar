# Add Account — Safe Flow / Quy trình thêm tài khoản an toàn

> Bilingual guide. English first, Tiếng Việt below.

---

## TL;DR

> **You do NOT need to `/logout` the current account in the terminal before adding a new one.** Claude Bar snapshots the active account's credentials into its Keychain backup *before* the new `/login` overwrites them. Logging out first throws away the live tokens and forces a re-login of the old account later.

> **KHÔNG cần `/logout` tài khoản hiện tại trong terminal trước khi thêm tài khoản mới.** Claude Bar tự động sao lưu credentials của tài khoản đang active vào Keychain *trước khi* `/login` mới ghi đè lên. Logout trước sẽ làm mất token đang sống và bắt bạn phải đăng nhập lại tài khoản cũ sau này.

---

## English

### Why the wizard is safe

Claude Code stores only **one** set of live credentials in the macOS Keychain at a time. Running `claude /login` overwrites whatever was there. The naive mental model — "I must `/logout` first so I don't corrupt the current account" — is exactly backwards: `/logout` deletes the live tokens **before** Claude Bar can copy them.

The **Add account** wizard handles this correctly:

1. You click **Settings → Accounts → Add account**.
2. Before opening Terminal, Claude Bar calls `snapshotActiveLive()` — it reads the **currently active** account's live credentials out of the Keychain and writes them into that account's per-slot backup. The old account is now safe.
3. Claude Bar opens a Terminal window pre-prepared for you.
4. You run `claude`, then `/login`, and finish the browser OAuth. This overwrites the Keychain's live slot with the **new** account's tokens — but the old account is already backed up, so nothing is lost.
5. Return to the wizard and click **I'm logged in**. Claude Bar snapshots the new live tokens into a new account slot and refreshes the UI.

After this, switching between accounts in the menu bar restores whichever backup you pick into the live Keychain slot. No re-login is ever required.

### Correct flow

```
Settings → Accounts → Add account
   ↓
(Claude Bar auto-snapshots the active account)
   ↓
Terminal opens → run `claude` → `/login` → finish in browser
   ↓
Back to wizard → "I'm logged in"
   ↓
Done. Both accounts are switchable from the menu bar.
```

### What NOT to do

- ❌ **Do not** run `/logout` in the terminal before adding a new account. The live tokens are gone the moment you `/logout`, and the snapshot step has nothing to copy.
- ❌ **Do not** run `claude /login` outside the wizard. The wizard's pre-login snapshot is the only thing protecting the previously-active account. Running `/login` from a plain terminal skips that snapshot and silently overwrites the live credentials of whichever account is currently active — that account will need a full re-login next time you switch to it.
- ❌ **Do not** delete `~/.claude.json` or Keychain entries by hand to "clean up". The per-account backups live there.

### What to do if you already ran `/logout` or `/login` outside the wizard

The previously-active account's live tokens are gone, but **its backup in Claude Bar may still be valid** if you added it through the wizard at some point. Switch to it from the menu bar — Claude Bar will restore the backup. If the backup is also stale (the inactive-account dot turns gray), open Terminal, run `claude /login` for that account, and use the wizard again so the fresh tokens are captured.

---

## Tiếng Việt

### Vì sao wizard an toàn

Claude Code chỉ lưu **một** bộ credentials live trong macOS Keychain tại một thời điểm. Chạy `claude /login` sẽ ghi đè lên bộ đang có. Cách nghĩ phổ biến — "phải `/logout` trước cho sạch" — là **sai hoàn toàn**: `/logout` xóa luôn token live **trước khi** Claude Bar kịp copy chúng ra backup.

Wizard **Add account** đã xử lý đúng quy trình này:

1. Bạn bấm **Settings → Accounts → Add account**.
2. Trước khi mở Terminal, Claude Bar gọi `snapshotActiveLive()` — đọc credentials live của tài khoản **đang active** từ Keychain và ghi vào backup riêng của tài khoản đó. Tài khoản cũ đã được giữ an toàn.
3. Claude Bar mở Terminal cho bạn.
4. Bạn chạy `claude`, gõ `/login`, hoàn tất OAuth trên browser. Lúc này Keychain bị ghi đè bằng token của tài khoản **mới** — nhưng tài khoản cũ đã được backup nên không mất gì.
5. Quay lại wizard, bấm **I'm logged in**. Claude Bar snapshot tài khoản mới vào một slot riêng và refresh UI.

Sau bước này, chuyển account từ menu bar chỉ là việc khôi phục backup tương ứng vào slot live trong Keychain. **Không bao giờ phải đăng nhập lại.**

### Quy trình đúng

```
Settings → Accounts → Add account
   ↓
(Claude Bar tự snapshot tài khoản đang active)
   ↓
Terminal mở → chạy `claude` → `/login` → hoàn tất trên browser
   ↓
Quay lại wizard → bấm "I'm logged in"
   ↓
Xong. Hai tài khoản đều switch được từ menu bar.
```

### Những điều KHÔNG được làm

- ❌ **Không** chạy `/logout` trong terminal trước khi thêm tài khoản mới. Vừa `/logout` xong là token live biến mất, bước snapshot không còn gì để copy.
- ❌ **Không** chạy `claude /login` bên ngoài wizard. Bước snapshot trước login chỉ tồn tại trong wizard — nó là thứ duy nhất bảo vệ tài khoản đang active. Chạy `/login` ngoài wizard sẽ âm thầm ghi đè credentials của tài khoản đang active, lần sau switch về tài khoản đó sẽ phải đăng nhập lại từ đầu.
- ❌ **Không** tự tay xóa `~/.claude.json` hay xóa entries trong Keychain để "dọn dẹp". Backup của từng account nằm ở đó.

### Nếu lỡ chạy `/logout` hoặc `/login` ngoài wizard thì sao?

Token live của tài khoản trước đó đã mất, nhưng **backup trong Claude Bar có thể vẫn còn** nếu trước đây bạn từng thêm nó qua wizard. Bấm chuyển sang account đó trong menu bar — Claude Bar sẽ khôi phục từ backup. Nếu backup cũng đã hết hạn (chấm bên cạnh account chuyển sang xám), mở Terminal, chạy `claude /login` cho account đó, rồi chạy lại wizard để token mới được snapshot lại.

---

## Quick reference / Tham chiếu nhanh

| Tình huống / Situation | Nên làm / Do | Không nên / Don't |
|---|---|---|
| Thêm account mới / Add new account | Settings → Add account wizard | `/logout` trước, hoặc `/login` ngoài wizard |
| Đổi account / Switch account | Click trên menu bar | Chạy `/login` lại |
| Account cũ hỏng / Old account broken | Wizard → snapshot lại | Xóa Keychain bằng tay |
