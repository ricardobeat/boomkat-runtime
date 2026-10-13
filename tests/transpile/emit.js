import {transpile} from "typescript";
import {readText} from "file";
import {args} from "process";
console.log(transpile(await readText(args[0]), {filename: args[0], module:args[1]!=="script", jsx:args[1]==="automatic"?"automatic":"classic", jsxFactory:"h", jsxFragmentFactory:"Fragment"}));
