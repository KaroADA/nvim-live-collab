use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:8080").await?;
    println!("Server listening on localhost:8080");

    loop {
        let (mut socket, addr) = listener.accept().await?;
        println!("New connection from: {}", addr);

        tokio::spawn(async move {
            let mut buffer = [0; 1024];
            match socket.read(&mut buffer).await {
                Ok(n) if n == 0 => return, // Connection closed
                Ok(n) => {
                    println!("Received: {}", String::from_utf8_lossy(&buffer[..n]));
                }
                Err(e) => eprintln!("Failed to read from socket: {}", e),
            }
        });
    }
}
