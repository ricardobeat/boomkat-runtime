import { test, describe } from "test";
test("not selected", () => { throw new Error("must not run"); });
test.only("selected", () => {});
describe.only("selected group", () => { test("inside", () => {}); });
