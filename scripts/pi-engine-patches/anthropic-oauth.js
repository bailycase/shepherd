// Shepherd's pi 1.0 OAuth API adapter. Request/stream behavior lives in the pinned port.
import { isClaudeOAuthAccessToken, loginAnthropic, refreshAnthropicToken } from "./anthropic-oauth/auth.js";
export { streamAnthropicOAuth } from "./anthropic-oauth/stream.js";
export { isClaudeOAuthAccessToken };

// pi 1.0 replaced the extension's callback API with AuthInteraction and requires
// a credential discriminator. Keep upstream's login, state validation and refresh.
export const anthropicOAuth = {
    name: "Anthropic (Claude Pro/Max)",
    isSubscription: true,
    async login(interaction) {
        const credentials = await loginAnthropic({
            signal: interaction.signal,
            onAuth: info => interaction.notify({ type: "auth_url", ...info }),
            onPrompt: info => interaction.prompt({ type: "manual_code", ...info, signal: interaction.signal }),
            onManualCodeInput: () => interaction.prompt({
                type: "manual_code", message: "Paste the callback URL or code#state:", signal: interaction.signal,
            }),
        });
        return { type: "oauth", ...credentials };
    },
    async refresh(credential) {
        return { type: "oauth", ...await refreshAnthropicToken(credential) };
    },
    async toAuth(credential) {
        return { apiKey: credential.access };
    },
};
