import { run } from "process";
import { assertEquals, test } from "test";

test("process.run applies cwd and stdio file actions", async () => {
    const { code, stdout, stderr } = await run("/bin/sh", {
        args: ["-c", "pwd; if read -r line; then exit 1; fi; printf error >&2"],
        cwd: "/",
        stdin: "null",
    });
    const decode = new TextDecoder();
    assertEquals(code, 0);
    assertEquals(decode.decode(stdout), "/\n");
    assertEquals(decode.decode(stderr), "error");
});
