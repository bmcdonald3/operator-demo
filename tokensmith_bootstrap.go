// bootServiceBootstrap is the spec for boot-service's bootstrap token —
// it writes inventory snapshots into SMD during background sync.
//
// Subject == ServiceBootService because tokensmith uses the `sub` claim
// for per-subject policy lookups; conventionally that matches the
// canonical service name.
var bootServiceBootstrap = bootstrapTokenSpec{
	secretSuffix: SuffixBootServiceBootstr,
	subject:      ServiceBootService,
	scopes:       "node:read,node:write",
	appName:      ServiceBootService,
}

// metadataServiceBootstrap is the spec for metadata-service's bootstrap
// token. metadata-service reads node + group information from SMD to
// serve cloud-init/metadata lookups; it never writes back, so the
// scopes are read-only.
var metadataServiceBootstrap = bootstrapTokenSpec{
	secretSuffix: SuffixMetadataServiceBootstr,
	subject:      ServiceMetadataService,
	scopes:       "node:read,group:read",
	appName:      ServiceMetadataService,
}

// mintBootstrapTokenViaExec runs `tokensmith bootstrap-token create`
// inside a Ready tokensmith pod, captures stdout (the JSON
// description of the new token, per --output-format json), parses out
// the opaque token string and returns it.
//
// Implementation notes:
//   - The CLI writes to the bootstrap store atomically; concurrent
//     reconciles minting at the same time would each get their own
//     valid token. We tolerate the dup write — the most recent token
//     is what we land in the Secret.
//   - The bootstrap-store path is passed explicitly so the result is
//     reproducible regardless of which tokensmith pod we land in.
func (r *TokensmithReconciler) mintBootstrapTokenViaExec(
	ctx context.Context, cp *openchamiv1alpha1.OpenCHAMIControlPlane, spec bootstrapTokenSpec,
) (string, error) {
	pod, err := r.pickTokensmithPod(ctx, cp)
	if err != nil {
		return "", err
	}

	args := []string{
		"/usr/local/bin/tokensmith", "bootstrap-token", "create",
		"--subject", spec.subject,
		"--audience", bootstrapTokenAudience,
		"--scopes", spec.scopes,
		"--ttl", bootstrapTokenTTL,
		"--refresh-ttl", bootstrapTokenRefreshTTL,
		"--output-format", "json",
		"--bootstrap-store", bootstrapTokenStorePath,
	}

	stdout, stderr, err := r.execInPod(ctx, ControlPlaneNamespace(cp), pod, args)
	if err != nil {
		return "", fmt.Errorf("exec %q in tokensmith pod %s: %w (stderr=%q)",
			args, pod, err, stderr)
	}

	var result bootstrapTokenCreateResult
	// The CLI's JSON output is the last well-formed JSON object on
	// stdout. Some tokensmith builds prepend banner text; skip past
	// anything before the first '{' to be robust to that.
	jsonStart := bytes.IndexByte(stdout, '{')
	if jsonStart < 0 {
		return "", fmt.Errorf("no JSON in tokensmith bootstrap-token create output: %q", string(stdout))
	}
	if err := json.Unmarshal(stdout[jsonStart:], &result); err != nil {
		return "", fmt.Errorf("parsing bootstrap-token create JSON: %w (raw=%q)", err, string(stdout))
	}
	if result.BootstrapToken == "" {
		return "", fmt.Errorf("bootstrap-token create returned empty bootstrap_token field: %q", string(stdout))
	}
	return result.BootstrapToken, nil
}
