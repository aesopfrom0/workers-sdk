import fs from "node:fs";
import path from "node:path";
import { describe, it } from "vitest";

type WranglerSchema = {
	definitions: {
		ContainerApp: {
			properties: Record<string, unknown>;
		};
		ContainerInstanceGroupConfig: {
			properties: Record<string, unknown> & {
				type: {
					const: string;
				};
			};
			required: string[];
		};
		DurableObjectBindings: {
			items: {
				$ref: string;
			};
		};
		DurableObjectBinding: {
			properties: {
				container: {
					$ref: string;
				};
			};
		};
		RawConfig: {
			properties: {
				build: {
					description: string;
					markdownDescription?: string;
				};
			};
		};
	};
};

function readSchema(): WranglerSchema {
	const schemaFile = path.join(__dirname, "../../../config-schema.json");
	return JSON.parse(fs.readFileSync(schemaFile, "utf-8")) as WranglerSchema;
}

describe("config schema", () => {
	it("documents ssh without exposing wrangler_ssh", ({ expect }) => {
		const schema = readSchema();

		expect(schema.definitions.ContainerApp.properties).toHaveProperty("ssh");
		expect(schema.definitions.ContainerApp.properties).not.toHaveProperty(
			"wrangler_ssh"
		);
	});

	it("documents Container Instance Groups on Durable Object bindings", ({
		expect,
	}) => {
		const schema = readSchema();
		const instanceGroup = schema.definitions.ContainerInstanceGroupConfig;

		expect(instanceGroup.properties.type.const).toBe("instance");
		expect(instanceGroup.required).toContain("type");
		expect(instanceGroup.required).toContain("name");
		expect(Object.keys(instanceGroup.properties)).toEqual(["type", "name"]);
		expect(schema.definitions.DurableObjectBindings.items.$ref).toBe(
			"#/definitions/DurableObjectBinding"
		);
		expect(
			schema.definitions.DurableObjectBinding.properties.container.$ref
		).toBe("#/definitions/ContainerInstanceGroupConfig");
	});

	it("emits markdownDescription for rich editor hovers", ({ expect }) => {
		const schema = readSchema();
		const build = schema.definitions.RawConfig.properties.build;

		expect(build.description).toContain(
			"[custom builds documentation](https://developers.cloudflare.com/workers/cli-wrangler/configuration#build)"
		);
		expect(build.markdownDescription).toContain(
			"[custom builds documentation](https://developers.cloudflare.com/workers/cli-wrangler/configuration#build)"
		);
	});
});
