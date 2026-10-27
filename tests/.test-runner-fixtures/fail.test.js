import { test, assertEquals } from "test";
test("wrong sum", () => { assertEquals(1 + 1, 3); });
test("floating rejection", () => { Promise.reject(new Error("floating")); });
test("passes after failures", () => {});
