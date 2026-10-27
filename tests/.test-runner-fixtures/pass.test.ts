import { test, describe, beforeAll, afterAll, beforeEach, assert, assertEquals, assertStrictEquals, assertMatch, assertThrows, assertRejects } from "test";
const order: string[] = [];
beforeAll(() => { order.push("beforeAll"); });
afterAll(() => { order.push("afterAll"); });
beforeEach(() => { order.push("each"); });
test("deep equality", () => {
    assertEquals({ a: [1, { b: new Set([1, 2]) }], d: new Date(0) }, { a: [1, { b: new Set([2, 1]) }], d: new Date(0) });
    assertEquals(new Uint8Array([1, 2]), new Uint8Array([1, 2]));
    assertThrows(() => assertEquals({ a: 1 }, { a: 1, b: undefined }));
    assertStrictEquals(NaN, NaN);
});
test("hooks ran", () => assertEquals(order, ["beforeAll", "each", "each"]));
describe("async", () => {
    test("awaits", async () => { await new Promise((r) => setTimeout(r, 2)); assert(true); });
    test("rejects", () => assertRejects(Promise.reject(new RangeError("range")), RangeError, "ran"));
    test.skip("skipped", () => { throw new Error("must not run"); });
    test.todo("todo");
});
test("match", () => assertMatch("hello world", /wor/));
