package Elara;

public class Error {
    public static <T> T undefined() {
        throw new RuntimeException("undefined");
    }
}