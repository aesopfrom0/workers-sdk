import { getCloudflareContainerRegistry } from "./knobs";
import type { ComplianceConfig } from "@cloudflare/workers-utils";

// The Cloudflare managed registry is special in that the namesapces for repos should always
// start with the Cloudflare Account tag
// This is a helper to generate the image tag with correct namespace attached to the Cloudflare Registry host
export const getCloudflareRegistryWithAccountNamespace = (
	accountID: string,
	tag: string,
	complianceConfig?: ComplianceConfig
): string => {
	return `${getCloudflareContainerRegistry(complianceConfig)}/${accountID}/${tag}`;
};

export const MF_DEV_CONTAINER_PREFIX = "cloudflare-dev";
