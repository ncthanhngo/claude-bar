# Hướng dẫn đồng bộ ClaudeBar giữa 2 máy chung iCloud

> File này copy sang **máy B** (máy chưa setup) rồi làm theo từ trên xuống.
> Máy A là máy đang chạy ngon, máy B là máy mới cần đồng bộ về.

---

## 0. Điều kiện cần

Cả 2 máy phải:

- [ ] Đăng nhập **cùng 1 Apple ID** trong System Settings → Apple ID.
- [ ] Bật **iCloud Drive** (System Settings → Apple ID → iCloud → iCloud Drive: **On**).
- [ ] iCloud Drive đã sync xong folder `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBar/`
      (mở Finder → iCloud Drive → thấy folder `ClaudeBar` không có icon ☁ tải xuống dở là OK).

---

## 1. Cài ClaudeBar trên máy B

Trên **máy A**:
```bash
cd ~/dev/02-claude-bar
make release
# → tạo release/ClaudeBar.zip
```

AirDrop file `release/ClaudeBar.zip` sang máy B, hoặc copy qua iCloud Drive / USB.

Trên **máy B**:
```bash
unzip ~/Downloads/ClaudeBar.zip -d /Applications/
xattr -cr /Applications/ClaudeBar.app    # gỡ Gatekeeper quarantine
open /Applications/ClaudeBar.app
```

Lần đầu mở Gatekeeper sẽ cảnh báo "unidentified developer" — bấm chuột phải vào app → **Open** → **Open**.

---

## 2. Enable iCloud sync trên máy B

1. Click icon ClaudeBar trên menu bar → tab **Diagnostics**.
2. Group **iCloud Sync** → bấm **Enable sync** (nút màu xanh đậm).
3. Nhập **passphrase**. **PHẢI là passphrase đã dùng trên máy A**:
   - Lấy lại từ máy A bằng cách mở **Keychain Access** trên máy A → tìm
     `claude-bar-cloudsync-passphrase` → tab "Attributes" hiện ra → tick
     "Show password" → nhập password đăng nhập Mac.
   - Hoặc trên máy A chạy:
     ```bash
     security find-generic-password -s "claude-bar-cloudsync-passphrase" -a passphrase -w
     ```
4. Máy B sẽ pull bundle về và hiển thị bảng preview các account.
5. Tick các account muốn bring in → **Restore selected (N)**.
6. Đợi vài giây, account list trên menu bar máy B sẽ hiện lên giống máy A.

---

## 3. Verify sync giữa 2 máy

### Cách 1 — Dùng script `sync-doctor`

Trên **máy A**:
```bash
cd ~/dev/02-claude-bar
bash scripts/sync-doctor.sh --short
```

Lưu lại output (1-4 dòng).

Trên **máy B** (sau khi clone hoặc copy `scripts/sync-doctor.sh` sang):
```bash
bash scripts/sync-doctor.sh --short
```

So sánh:

| Field | Yêu cầu |
|---|---|
| `seq=` | Lệch ≤ 2 giữa 2 máy |
| `hash=` | Có thể khác (lastBundleHash là hash của ciphertext, mỗi push tạo bundle khác do salt + seq mới) |
| `icloud=` | Cả 2 phải là `in-sync` |
| `accounts=` | Số account phải giống nhau |
| Các dòng identity hash (sha256) | Phải khớp **đúng tuyệt đối** từng dòng |

### Cách 2 — Test end-to-end thủ công

1. Trên **máy A**: rename 1 account (vd. thêm emoji `🧪` vào nickname).
2. Đợi **30 giây** cho iCloud Drive propagate.
3. Trên **máy B**: bấm **Sync now** trong Diagnostics → `lastSeq` tăng lên.
4. Mở menu bar máy B → account list phải hiện nickname mới có `🧪`.

Nếu bước 4 không thấy:
- Check chip sync trên header Accounts (tab Claude) — nếu đỏ → vô Diagnostics đọc lỗi.
- Bấm **Restore** trong Diagnostics để ép pull lại.

---

## 4. Sau khi đồng bộ — tận hưởng

Từ giờ:

- **Tự động chu kỳ 6h** mỗi máy sẽ pull→refresh→push background.
- **Switch account trên 1 máy** → autopush ngay → máy kia pull lần sau sẽ có.
- **Chip xanh ✓ Xm** ở tab Claude header báo sync health.
- **Nếu chip thành đỏ** "sync failing" → vô Diagnostics đọc reason, hoặc bấm Sync now để chẩn đoán.

---

## 5. Troubleshooting

**Máy B nhập passphrase mà báo "decrypt failed":**
- Passphrase chắc chắn đúng? Thử copy lại từ máy A (xem mục 2).
- Passphrase có khoảng trắng đầu/cuối không (Keychain Access đôi khi paste lỗi)?

**Máy B không thấy bundle nào trong iCloud:**
- Mở Finder → iCloud Drive → folder `ClaudeBar` đã sync chưa? Nếu có icon ☁ → đợi tải xuống.
- iCloud Drive đã enable cho `Desktop & Documents Folders` chưa cũng không quan trọng — bundle nằm trong container riêng.

**lastSeq lệch nhau quá xa (vd. máy A=47, máy B=20):**
- Máy B chưa pull gần đây. Bấm **Sync now** ở Diagnostics → vài giây sau check lại.
- Hoặc auto-sync 6h chưa tới chu kỳ — chấp nhận, để 6h sau check lại.

**Account list máy B sai (thiếu / thừa account):**
- Vô Diagnostics → **Restore** → bảng preview cho phép tick lại các account cần.
- KHÔNG đụng vào identity hash dài 12 ký tự — đó là so sánh nội bộ, không phải account name.

**App crash khi mở lần đầu:**
- Xem file `~/Library/Application Support/claude-swap-widget/logs/` — có log đầy đủ.
- Hoặc chạy thẳng từ Terminal để xem error:
  ```bash
  /Applications/ClaudeBar.app/Contents/MacOS/ClaudeSwapWidget
  ```

---

## 6. Cleanup / di chuyển account sang máy khác (1 chiều)

Nếu không định dùng máy A nữa, chỉ giữ máy B:

1. Máy B verify sync ok như mục 3.
2. Máy A: Diagnostics → **Forget** (xoá bundle khỏi iCloud + xoá local sync state).
3. Hoặc: gỡ ClaudeBar khỏi máy A:
   ```bash
   rm -rf /Applications/ClaudeBar.app
   rm -rf ~/Library/Application\ Support/claude-swap-widget
   ```
   (account credentials trong Keychain máy A vẫn còn — có thể xoá thủ công nếu muốn).
