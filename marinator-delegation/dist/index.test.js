import { describe, expect, it } from "vitest";
import entry from "./index.js";
import { getToolPluginMetadata } from "openclaw/plugin-sdk/tool-plugin";
describe("marinator-delegation", () => {
    it("declares Marinator delegation tool metadata", () => {
        expect(getToolPluginMetadata(entry)?.tools.map((tool) => tool.name)).toEqual(["marinator_delegate"]);
    });
});
