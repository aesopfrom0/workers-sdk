import {
	COMPLIANCE_REGION_CONFIG_UNKNOWN,
	getComplianceRegionSubdomain,
} from "@cloudflare/workers-utils";
import { MF_DEV_CONTAINER_PREFIX } from "./registry";
import type { ComplianceConfig } from "@cloudflare/workers-utils";

// Returns the managed registry for the configured API environment and compliance region.
// The default registry can be overridden with CLOUDFLARE_CONTAINER_REGISTRY.
export const getCloudflareContainerRegistry = (
	complianceConfig: ComplianceConfig = COMPLIANCE_REGION_CONFIG_UNKNOWN
) => {
	// previously defaulted to registry.cloudchamber.cfdata.org
	if (process.env.CLOUDFLARE_CONTAINER_REGISTRY) {
		return process.env.CLOUDFLARE_CONTAINER_REGISTRY;
	}

	const environmentPrefix =
		process.env.WRANGLER_API_ENVIRONMENT === "staging" ? "staging." : "";
	const complianceRegionSubdomain =
		getComplianceRegionSubdomain(complianceConfig);

	return `${environmentPrefix}registry${complianceRegionSubdomain}.cloudflare.com`;
};

/** Prefixes with the cloudflare-dev namespace. The name should be the container's DO classname, and the tag a build uuid. */
export const getDevContainerImageName = (name: string, tag: string) => {
	return `${MF_DEV_CONTAINER_PREFIX}/${name.toLowerCase()}:${tag}`;
};
