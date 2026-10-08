const AUTH_ERROR_MESSAGES = Object.freeze({
    invalid_credentials: 'The saved session or pairing code is invalid. Enter a new pairing code.',
    rate_limited: 'Too many attempts. Wait a minute before trying again.',
    session_capacity: 'The server has reached its session limit. Revoke an old session, then try again.',
    insufficient_permissions: 'This session is not allowed to perform that operation.',
    authentication_required: 'Pair with the server before continuing.',
    unsupported_protocol_version: 'This configurator is not compatible with the server protocol.',
});

const CONFIG_ERROR_MESSAGES = Object.freeze({
    config_conflict: 'The server config changed elsewhere. Your local edits are preserved; reload before saving.',
    invalid_revision: 'The server rejected the config revision. Reload before saving again.',
    unsupported_config_version: 'The server does not support this config version.',
    invalid_config: 'The server rejected this configuration. Your edits are preserved.',
});

export function authErrorMessage(code) {
    return AUTH_ERROR_MESSAGES[code] ?? 'Authentication was not accepted. Try again.';
}

export function configErrorMessage(code) {
    return CONFIG_ERROR_MESSAGES[code] ?? 'The server rejected this configuration. Your edits are preserved.';
}

export function shouldPreserveLocalDraft(configData, isDirty) {
    return configData !== null && isDirty;
}

export function hasUsableRevision(revision) {
    return Number.isSafeInteger(revision) && revision >= 0;
}
