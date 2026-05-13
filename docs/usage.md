# Usage

## First run

```bash
bash scripts/build-app.sh
open "dist/Claude Widget.app"
```

macOS sẽ chặn vì app chưa được Developer ID sign:
- System Settings → Privacy & Security → cuộn xuống thấy "Claude Widget" was blocked → **Open Anyway**.
- Hoặc right-click app → **Open** → **Open** lần thứ hai trong dialog.

Sau khi mở, **icon đồng hồ tốc độ + label %·hh:mm** sẽ xuất hiện trên menu bar.

## Đọc menu bar

Format: `<percent>% · <hh>h<mm>m`

Ví dụ `47% · 2h13m` = đã dùng 47% giới hạn 5h block, còn 2h13m thì reset.

Màu thay đổi theo ngưỡng:
- < 60% → xanh lá
- 60-85% → cam
- ≥ 85% → đỏ

## Popover

Click vào label → popover hiện:

1. **% lớn + countdown** — số liệu hiện tại của 5h block active.
2. **Progress bar** đổi màu theo mức.
3. **Tokens / Limit / Msgs** — tổng token (input+output+cache), giới hạn plan, số tin nhắn.
4. **Block: HH:MM → HH:MM** — thời điểm bắt đầu/kết thúc block.
5. **Accounts** — danh sách profile đã lưu.
   - "Add" để snapshot credentials hiện tại.
   - "Switch" để đổi sang profile khác.
   - Thùng rác để xóa profile.
6. **Settings (bánh răng)** — chọn plan (Pro / Max5 / Max20 / Custom).
7. **Refresh (mũi tên xoay)** — rescan JSONL ngay.

## Multi-account workflow

### Tạo profile đầu tiên

1. Đang login Claude Code ở account A.
2. Mở widget → **Add** → đặt tên (vd `personal`) → giữ source mặc định.
3. App copy `~/.claude/.credentials.json` vào `~/Library/Application Support/ClaudeWidget/profiles/personal/credentials.json`.

### Tạo profile thứ hai

1. Đăng xuất account A khỏi Claude Code (hoặc `claude logout`).
2. Đăng nhập account B.
3. Mở widget → **Add** → đặt tên (vd `work`).

### Switch

1. Khi profile active gần hết token (cam/đỏ), click **Switch** ở profile khác.
2. App backup credentials hiện tại vào `~/Library/Application Support/ClaudeWidget/backups/credentials-<timestamp>.json`.
3. Copy credentials của profile chọn đè lên `~/.claude/.credentials.json`.
4. **Restart Claude Code** (cmd-q rồi mở lại, hoặc reload window) để load credentials mới.

> **Lưu ý**: widget không signal được Claude Code đang chạy đổi credentials, nên phải restart manually. Đây là giới hạn tự nhiên của OAuth flow.

## Plan limits

Số liệu mặc định (combined input+output+cache token mỗi 5h block):

| Plan    | Limit       |
| ------- | ----------- |
| Pro     | 19,000,000  |
| Max 5×  | 88,000,000  |
| Max 20× | 220,000,000 |
| Custom  | tùy chỉnh   |

Anthropic không công bố con số chính xác — đây là heuristic dựa trên ccusage. Nếu thực tế hit limit sớm/muộn hơn so với chỉ báo, vào **Settings → Custom** rồi điều chỉnh.

## File locations

| Mục đích          | Đường dẫn                                                        |
| ----------------- | ---------------------------------------------------------------- |
| Config            | `~/Library/Application Support/ClaudeWidget/config.json`         |
| Profiles          | `~/Library/Application Support/ClaudeWidget/profiles/<name>/`    |
| Backups           | `~/Library/Application Support/ClaudeWidget/backups/`            |
| Claude usage logs | `~/.claude/projects/<project>/<session>.jsonl` (read-only access) |
| Claude creds      | `~/.claude/.credentials.json` (written only on Switch)           |

## Refresh schedule

- UI tick (label cập nhật): **5 giây**.
- JSONL rescan (đọc file): **15 giây** + ngay khi click refresh trên popover.

## Troubleshooting

**Label hiện `idle`**
→ Không tìm thấy assistant message nào trong 5h gần đây hoặc `~/.claude/projects/` rỗng. Mở Claude Code và gửi một tin nhắn để khởi tạo block.

**Label hiện `··`**
→ Đang scan lần đầu — đợi 1-2 giây.

**App không hiện trên menu bar**
→ Menu bar đầy? Thử mở rộng bằng `Cmd-drag` icon. Hoặc activity monitor → kill `ClaudeWidget` → mở lại.

**Switch không có tác dụng**
→ Phải **restart Claude Code** sau khi switch để load credentials mới.

**Credentials lỗi sau khi switch**
→ Restore từ `~/Library/Application Support/ClaudeWidget/backups/credentials-<latest>.json` đè lên `~/.claude/.credentials.json`.
