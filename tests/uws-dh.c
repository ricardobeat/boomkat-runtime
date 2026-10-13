#include "libusockets.h"
#include <assert.h>
#include <stddef.h>

int main(int argc, char **argv) {
    assert(argc == 4);
    struct us_loop_t *loop = us_create_loop(NULL, NULL, NULL, NULL, 0);
    assert(loop);
    struct us_socket_context_options_t options = {0};
    options.dh_params_file_name = argv[1];
    struct us_socket_context_t *context = us_create_socket_context(1, loop, 0, options);
    assert(context);
    us_socket_context_free(1, context);
    options.dh_params_file_name = argv[2];
    assert(!us_create_socket_context(1, loop, 0, options));
    options.dh_params_file_name = argv[3];
    assert(!us_create_socket_context(1, loop, 0, options));
    options.dh_params_file_name = "/nonexistent/taskboard-dh-parameters.pem";
    assert(!us_create_socket_context(1, loop, 0, options));
    us_loop_free(loop);
    return 0;
}
