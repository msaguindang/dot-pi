import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { google } from "googleapis";

const run = promisify(execFile);

const INFISICAL_DOMAIN = "http://localhost:8080";
const INFISICAL_TIMEOUT_MS = 15_000;
const CREDS_DIR = join(homedir(), ".config", "infisical-machine");
const PROJECT_FILE = join(homedir(), ".pi", "agent", ".infisical.json");

// Cache secrets
const secrets = new Map<string, string>();
let loading: Promise<void> = Promise.resolve();

// Machine-identity login (renews without a browser) so a lapsed user session can never block pi.
async function loadSecrets(): Promise<void> {
    const clientId = readFileSync(join(CREDS_DIR, "client-id"), "utf-8").trim();
    const clientSecret = readFileSync(join(CREDS_DIR, "client-secret"), "utf-8").trim();
    const projectId = (JSON.parse(readFileSync(PROJECT_FILE, "utf-8")) as { workspaceId?: string }).workspaceId ?? "";
    if (clientId.length === 0 || clientSecret.length === 0 || projectId.length === 0) {
        throw new Error("Machine identity files or project id missing");
    }
    const opts = { encoding: "utf-8" as const, timeout: INFISICAL_TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"] };
    const login = await run("infisical", [
        "login", "--method=universal-auth", `--client-id=${clientId}`, `--client-secret=${clientSecret}`,
        "--plain", "--silent", "--domain", INFISICAL_DOMAIN,
    ], opts as never);
    const token = String(login.stdout).trim();
    if (token.length === 0) throw new Error("Infisical login returned no token");
    const exported = await run("infisical", [
        "export", "--domain", INFISICAL_DOMAIN, "--projectId", projectId, "--env", "dev", "--format=dotenv",
    ], { ...opts, env: { ...process.env, INFISICAL_TOKEN: token } } as never);
    for (const line of String(exported.stdout).split("\n")) {
        const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
        if (match) secrets.set(match[1], match[2].replace(/^["']|["']$/g, ""));
    }
}

function getSecret(key: string): string {
    return secrets.get(key) ?? process.env[key] ?? "";
}

async function getAuthClient() {
    await loading;
    const clientId = getSecret("GMAIL_CLIENT_ID");
    const clientSecret = getSecret("GMAIL_CLIENT_SECRET");
    const refreshToken = getSecret("GMAIL_REFRESH_TOKEN");

    if (!clientId || !clientSecret || !refreshToken) {
        throw new Error("Missing Gmail API credentials in Infisical (GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN).");
    }

    const auth = new google.auth.OAuth2(clientId, clientSecret);
    auth.setCredentials({ refresh_token: refreshToken });
    return auth;
}

function makeRawEmail(to: string, subject: string, body: string, cc?: string): string {
    const lines = [
        `To: ${to}`,
        `Subject: ${subject}`,
        `MIME-Version: 1.0`,
        `Content-Type: text/plain; charset="UTF-8"`
    ];
    if (cc) {
        lines.push(`Cc: ${cc}`);
    }
    lines.push("", body);
    const str = lines.join("\r\n");
    
    return Buffer.from(str)
        .toString("base64")
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");
}

export default function (pi: ExtensionAPI) {
    pi.on("session_start", (_event, ctx) => {
        secrets.clear();
        // Not awaited: pi opens immediately; Gmail tools wait on `loading` when first used.
        loading = loadSecrets().catch((error: unknown) => {
            const reason = error instanceof Error ? error.message.split("\n")[0] : String(error);
            ctx.ui.notify(`[gmail] could not load secrets from Infisical: ${reason}`);
        });
    });

    pi.on("session_shutdown", () => {
        secrets.clear();
    });

    pi.registerTool({
        name: "search_emails",
        description: "Search your Gmail inbox using standard Gmail search queries.",
        parameters: Type.Object({
            query: Type.String({ description: "Gmail search query (e.g. 'is:unread from:boss@example.com')" }),
            maxResults: Type.Optional(Type.Number({ description: "Max results to return (default: 5)" }))
        }),
        execute: async (_callId, params) => {
            const { query, maxResults = 5 } = params as { query: string; maxResults?: number };
            const auth = await getAuthClient();
            const gmail = google.gmail({ version: "v1", auth });
            
            const res = await gmail.users.messages.list({
                userId: "me",
                q: query,
                maxResults
            });
            
            if (!res.data.messages || res.data.messages.length === 0) {
                return { content: [{ type: "text", text: "No emails found matching the query." }] };
            }

            const messages = [];
            for (const msg of res.data.messages) {
                const msgRes = await gmail.users.messages.get({
                    userId: "me",
                    id: msg.id!,
                    format: "metadata",
                    metadataHeaders: ["Subject", "From", "Date"]
                });
                
                const headers = msgRes.data.payload?.headers || [];
                const subject = headers.find(h => h.name === "Subject")?.value || "(No Subject)";
                const from = headers.find(h => h.name === "From")?.value || "(Unknown)";
                const date = headers.find(h => h.name === "Date")?.value || "(Unknown)";
                
                messages.push(`ID: ${msg.id}\nFrom: ${from}\nDate: ${date}\nSubject: ${subject}\nSnippet: ${msgRes.data.snippet}\n`);
            }

            return { content: [{ type: "text", text: messages.join("\n---\n") }] };
        }
    });

    pi.registerTool({
        name: "read_email",
        description: "Read the full content of a specific email by its ID.",
        parameters: Type.Object({
            id: Type.String({ description: "The email ID to read" })
        }),
        execute: async (_callId, params) => {
            const { id } = params as { id: string };
            const auth = await getAuthClient();
            const gmail = google.gmail({ version: "v1", auth });
            
            const res = await gmail.users.messages.get({
                userId: "me",
                id: id,
                format: "full"
            });
            
            let body = "";
            const getBody = (part: any) => {
                if (part.mimeType === "text/plain" && part.body?.data) {
                    body += Buffer.from(part.body.data, "base64").toString("utf-8");
                } else if (part.parts) {
                    part.parts.forEach(getBody);
                }
            };
            
            if (res.data.payload) {
                getBody(res.data.payload);
            }
            if (!body && res.data.snippet) {
                body = `(Could not extract plain text body. Snippet: ${res.data.snippet})`;
            }

            return { content: [{ type: "text", text: body }] };
        }
    });

    pi.registerTool({
        name: "draft_email",
        description: "Create a draft email in your Gmail account without sending it.",
        parameters: Type.Object({
            to: Type.String(),
            subject: Type.String(),
            body: Type.String(),
            cc: Type.Optional(Type.String())
        }),
        execute: async (_callId, params) => {
            const { to, subject, body, cc } = params as { to: string; subject: string; body: string; cc?: string };
            const auth = await getAuthClient();
            const gmail = google.gmail({ version: "v1", auth });
            
            const raw = makeRawEmail(to, subject, body, cc);
            
            const res = await gmail.users.drafts.create({
                userId: "me",
                requestBody: {
                    message: { raw }
                }
            });
            
            return { content: [{ type: "text", text: `Draft created successfully! Draft ID: ${res.data.id}` }] };
        }
    });

    pi.registerTool({
        name: "send_email",
        description: "Send an email immediately. Triggers a mandatory user confirmation guardrail.",
        parameters: Type.Object({
            to: Type.String(),
            subject: Type.String(),
            body: Type.String(),
            cc: Type.Optional(Type.String())
        }),
        execute: async (_callId, params, _signal, _onUpdate, ctx) => {
            const { to, subject, body, cc } = params as { to: string; subject: string; body: string; cc?: string };
            
            if (!ctx.hasUI) {
                throw new Error("Cannot send email without UI confirmation.");
            }

            const ok = await ctx.ui.confirm(
                "GUARDRAIL: SEND EMAIL",
                `Are you sure you want to send this email?\n\nTo: ${to}\nCc: ${cc || "none"}\nSubject: ${subject}\n\nBody:\n${body}`
            );

            if (!ok) {
                return { content: [{ type: "text", text: "Email sending cancelled by user." }] };
            }

            const auth = await getAuthClient();
            const gmail = google.gmail({ version: "v1", auth });
            
            const raw = makeRawEmail(to, subject, body, cc);
            
            await gmail.users.messages.send({
                userId: "me",
                requestBody: { raw }
            });
            
            return { content: [{ type: "text", text: `Email sent successfully to ${to}!` }] };
        }
    });
}
