import type { Config } from "@cloudflare/workers-utils";

export function getContainerMetadata(
	config: Config
): { class_name: string }[] | undefined {
	const classNames = new Set(
		config.containers?.map((container) => container.class_name) ?? []
	);

	for (const binding of config.durable_objects.bindings) {
		if (binding.container?.type === "instance") {
			classNames.add(binding.class_name);
		}
	}

	return classNames.size === 0
		? undefined
		: Array.from(classNames, (class_name) => ({ class_name }));
}
