use mobi::Mobi;

fn main() {
    let path = r"C:\Users\Administrator\Desktop\TeleAgent的工作空间\test_book.mobi";
    match Mobi::from_path(path) {
        Ok(m) => {
            println!("Title: {:?}", m.title());
            println!("Author: {:?}", m.author());
            // content_as_string_lossy 处理非 UTF-8 编码（如 Windows-1252）
            let text = m.content_as_string_lossy();
            println!("Content length: {} chars", text.len());
            println!("Content preview: {}...", &text[..text.len().min(500)]);
            println!("\n--- HTML stripping test ---");
            // 测试 strip_html_to_text（通过 FFI 函数的内部逻辑）
            let plain = strip_html(&text);
            println!("Plain text length: {} chars", plain.len());
            println!("Plain text preview: {}...", &plain[..plain.len().min(500)]);
        }
        Err(e) => println!("Failed to open MOBI: {:?}", e),
    }
}

fn strip_html(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut tag_name = String::new();
    let mut collecting_tag = false;

    for ch in html.chars() {
        match ch {
            '<' => {
                in_tag = true;
                collecting_tag = true;
                tag_name.clear();
            }
            '>' => {
                in_tag = false;
                collecting_tag = false;
                let tag_lower = tag_name.to_lowercase();
                if tag_lower.starts_with("p")
                    || tag_lower.starts_with("div")
                    || (tag_lower.starts_with("h") && tag_lower.len() <= 2)
                    || tag_lower == "br"
                    || tag_lower == "li"
                    || tag_lower == "tr"
                {
                    result.push('\n');
                }
                tag_name.clear();
            }
            _ if in_tag => {
                if collecting_tag {
                    if ch.is_whitespace() || ch == '/' {
                        collecting_tag = false;
                    } else {
                        tag_name.push(ch.to_ascii_lowercase());
                    }
                }
            }
            _ if !in_tag => {
                result.push(ch);
            }
            _ => {}
        }
    }

    result.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}
