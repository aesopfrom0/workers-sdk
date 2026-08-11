import { ContainerInstanceGroupsService } from "@cloudflare/containers-shared";
import { fillOpenAPIConfiguration } from "../cloudchamber/common";
import { createDurableObjectNamespaceResolver } from "./deploy";
import { containersScope } from ".";
import type { PutContainerInstanceGroupRequestBody } from "@cloudflare/containers-shared";
import type {
	Config,
	DurableObjectBinding,
	ContainerInstanceGroupConfig,
} from "@cloudflare/workers-utils";

type DeployContainerInstanceGroupsArgs = {
	versionId: string;
	accountId: string;
	scriptName: string;
};

type ContainerInstanceGroupBinding = DurableObjectBinding & {
	container: ContainerInstanceGroupConfig;
};

function isContainerInstanceGroupBinding(
	binding: DurableObjectBinding
): binding is ContainerInstanceGroupBinding {
	return binding.container?.type === "instance";
}

function toRequestBody(
	binding: ContainerInstanceGroupBinding
): PutContainerInstanceGroupRequestBody {
	return {
		class_name: binding.class_name,
		name: binding.container.name,
	};
}

export async function deployContainerInstanceGroups(
	config: Config,
	{ versionId, accountId, scriptName }: DeployContainerInstanceGroupsArgs
): Promise<void> {
	const groups = config.durable_objects.bindings.filter(
		isContainerInstanceGroupBinding
	);
	if (groups.length === 0) {
		return;
	}

	await fillOpenAPIConfiguration(config, containersScope);
	const resolveNamespaceId = createDurableObjectNamespaceResolver(config, {
		versionId,
		accountId,
		scriptName,
	});

	for (const group of groups) {
		const namespaceId = await resolveNamespaceId(group.class_name);
		await ContainerInstanceGroupsService.putContainerInstanceGroup(
			namespaceId,
			toRequestBody(group)
		);
	}
}
