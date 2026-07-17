use mobi::Mobi;

fn main() {
    let path = r"C:\Users\Administrator\Desktop\TeleAgent的工作空间\test_book.mobi";
    match Mobi::from_path(path) {
        Ok(m) => {
            println!("Title: {:?}", m.title());
            println!("Author: {:?}", m.author());
            let content = m.content_as_string();
            match content {
                Ok(text) => {
                    println!("Content length: {} bytes", text.len());
                    println!("Content preview: {}...", &text[..text.len().min(200)]);
                }
                Err(e) => println!("Content extraction error: {:?}", e),
            }
        }
        Err(e) => println!("Failed to open MOBI: {:?}", e),
    }
}
