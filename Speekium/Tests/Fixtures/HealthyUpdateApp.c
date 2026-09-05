#include <fcntl.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    const char *health_file = NULL;
    const char *health_token = NULL;
    for (int index = 1; index + 1 < argc; index += 1) {
        if (strcmp(argv[index], "--speekium-update-health-file") == 0) {
            health_file = argv[index + 1];
        } else if (strcmp(argv[index], "--speekium-update-health-token") == 0) {
            health_token = argv[index + 1];
        }
    }
    if (health_file == NULL || health_token == NULL) {
        return 0;
    }
    int descriptor = open(health_file, O_WRONLY | O_TRUNC);
    if (descriptor < 0) {
        return 1;
    }
    size_t length = strlen(health_token);
    ssize_t written = write(descriptor, health_token, length);
    close(descriptor);
    if (written != (ssize_t)length) {
        return 1;
    }
    sleep(4);
    return 0;
}
