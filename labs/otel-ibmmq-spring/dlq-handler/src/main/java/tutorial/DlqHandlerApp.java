package tutorial;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class DlqHandlerApp {
    public static void main(String[] args) {
        SpringApplication.run(DlqHandlerApp.class, args);
    }
}
