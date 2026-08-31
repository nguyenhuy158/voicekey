import Foundation

/// UI strings. English is the key, so untranslated text still reads fine.
/// `Config.uiLanguage` is "system" (follow macOS), "en" or "vi".
func T(_ s: String) -> String {
    guard uiLang() == "vi", let v = viStrings[s] else { return s }
    return v
}

func uiLang() -> String {
    let c = Settings.shared.cfg.uiLanguage
    if c != "system" { return c }
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? "vi" : "en"
}

let uiLanguages: [(String, String)] = [
    ("system", "System"), ("en", "English"), ("vi", "Tiếng Việt"),
]

let viStrings: [String: String] = [
    // tabs / window
    "Account": "Tài khoản",
    "Built": "Build ngày",
    "Running commit": "Đang chạy commit",
    "or": "hoặc",
    "System": "Hệ thống",
    "Nothing recorded yet.\nHold your key and talk.": "Chưa ghi gì.\nGiữ phím của bạn và nói.",
    "No transcript matches": "Không có bản ghi nào khớp",
    "Sign in": "Đăng nhập",
    "this Mac": "máy Mac này",
    "Accounts aren't supported — VoiceKey has no server to sign into.":
        "Không hỗ trợ tài khoản — VoiceKey không có máy chủ để đăng nhập.",
    "Local Plan": "Gói cục bộ",
    "Unlimited words. Audio never leaves this Mac.":
        "Không giới hạn số từ. Âm thanh không bao giờ rời máy Mac này.",
    "History": "Lịch sử",
    "Stats": "Thống kê",
    "Settings": "Cài đặt",

    // menus
    "Settings…": "Cài đặt…",
    "Hide VoiceKey": "Ẩn VoiceKey",
    "Close Window": "Đóng cửa sổ",
    "Quit VoiceKey": "Thoát VoiceKey",
    "Quit": "Thoát",
    "Cut": "Cắt",
    "Copy": "Sao chép",
    "Paste": "Dán",
    "Select All": "Chọn tất cả",
    "Open VoiceKey": "Mở VoiceKey",
    "Hold": "Giữ",

    // HUD
    "Transcribing…": "Đang chuyển văn bản…",

    // history
    "Stop": "Dừng",
    "Play recording": "Phát bản ghi",
    "No speech detected": "Không nhận được giọng nói",
    "Copy text": "Sao chép văn bản",
    "Delete": "Xoá",
    "Clear all": "Xoá tất cả",
    "Search transcripts": "Tìm trong bản ghi",
    "kept": "đã lưu",
    "of": "trên",

    // stats
    "Total Words": "Tổng số từ",
    "of typing.": "gõ phím.",
    "VoiceKey saved you": "VoiceKey đã tiết kiệm cho bạn",
    "words to Lv.": "từ nữa lên Lv.",
    "today": "hôm nay",
    "Level": "Cấp",
    "Top App": "Ứng dụng nhiều nhất",
    "Streak": "Chuỗi ngày",
    "Spoken": "Đã nói",
    "day": "ngày",
    "days": "ngày",
    "Less": "Ít",
    "More": "Nhiều",
    "words": "từ",
    "Nothing dictated yet — hold a key and talk.": "Chưa đọc gì — giữ một phím và nói.",
    "Reset stats": "Đặt lại thống kê",

    // settings
    "Hold to talk": "Giữ để nói",
    "Key 1": "Phím 1",
    "Key 2": "Phím 2",
    "Press a key…": "Nhấn một phím…",
    "Press…": "Nhấn…",
    "Click, then hold the key you want to use": "Bấm vào đây, rồi giữ phím bạn muốn dùng",
    "Each key is pinned to one language — whisper can't reliably mix two in one sentence.":
        "Mỗi phím gắn với một ngôn ngữ — whisper không trộn được hai ngôn ngữ trong một câu.",
    "Keybindings": "Phím tắt",
    "Activate Hands Free": "Bật chế độ rảnh tay",
    "Tap once to start, tap again to stop. Uses": "Nhấn một lần để bắt đầu, nhấn lại để dừng. Dùng",
    "Paste Last Transcript": "Dán bản ghi gần nhất",
    "Paste the previous result again, without re-recording.":
        "Dán lại kết quả trước đó mà không cần ghi âm lại.",
    "Double-Tap to Latch": "Nhấn đúp để ghi liên tục",
    "Double-tap a talk key to keep recording hands-free; tap once more to finish.":
        "Nhấn đúp phím nói để ghi rảnh tay; nhấn thêm một lần nữa để kết thúc.",
    "Cancel with Escape": "Huỷ bằng phím Escape",
    "Throw away the clip in progress — nothing is transcribed or pasted.":
        "Bỏ đoạn đang ghi — không chuyển văn bản, không dán.",
    "Unbind": "Bỏ gán phím",
    "Model": "Mô hình",
    "Whisper model": "Mô hình Whisper",
    "Model file is missing — run ./setup.sh": "Thiếu file mô hình — chạy ./setup.sh",
    "Interface Language": "Ngôn ngữ giao diện",
    "Language of the VoiceKey window and menus.": "Ngôn ngữ của cửa sổ và menu VoiceKey.",
    "Show Floating Bar": "Hiện thanh nổi",
    "Always show the bar at the bottom of your screen.":
        "Luôn hiện thanh ở cạnh dưới màn hình.",
    "Play Sounds": "Phát âm thanh",
    "A tick when recording starts, a pop when the text lands.":
        "Một tiếng tích khi bắt đầu ghi, một tiếng bụp khi có chữ.",
    "Avoid Clipboard History": "Tránh lịch sử clipboard",
    "Marks the paste as concealed so clipboard managers skip it.":
        "Đánh dấu nội dung dán là ẩn để trình quản lý clipboard bỏ qua.",
    "Privacy Mode": "Chế độ riêng tư",
    "Don't keep the audio or the transcript in History.":
        "Không lưu âm thanh hay bản ghi vào Lịch sử.",
    "Open at Login": "Mở khi đăng nhập",
    "Start VoiceKey when your computer starts.": "Chạy VoiceKey khi máy khởi động.",
    "Accessibility Permission": "Quyền trợ năng",
    "Required. Used to read the hold-key and paste the text.":
        "Bắt buộc. Dùng để đọc phím giữ và dán văn bản.",
    "Granted": "Đã cấp",
    "Grant…": "Cấp quyền…",
    "Reset to Defaults": "Khôi phục mặc định",

    // alerts
    "Model missing": "Thiếu mô hình",
    "whisper-cli not found": "Không tìm thấy whisper-cli",
]

#if DEBUG_L10N
func demoL10n() {
    assert(T("History") == "History" || T("History") == "Lịch sử")
    assert(viStrings["Settings"] == "Cài đặt")
}
#endif
