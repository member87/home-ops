// Prints a GitHub App installation token for Chore Bore, scoped to one repository.
// The Renovate CLI cannot authenticate as a GitHub App on its own: it needs an
// installation token (ghs_...), which GitHub expires after one hour.
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";

const { CHORE_BORE_APP_ID: appId, CHORE_BORE_REPOSITORY: repository, CHORE_BORE_PRIVATE_KEY_FILE: keyFile } =
  process.env;
if (!appId || !repository || !keyFile) {
  throw new Error("CHORE_BORE_APP_ID, CHORE_BORE_REPOSITORY and CHORE_BORE_PRIVATE_KEY_FILE must be set");
}

// createPrivateKey reads both PKCS#1 (what GitHub hands out) and PKCS#8 PEM.
const key = createPrivateKey(readFileSync(keyFile));
const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
// iat is backdated to absorb clock skew; GitHub rejects an exp more than 10 minutes out.
const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({ iat: now - 60, exp: now + 540, iss: appId })}`;
const jwt = `${unsigned}.${sign("sha256", Buffer.from(unsigned), key).toString("base64url")}`;

async function github(method, path, body) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${jwt}`,
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: body && JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`${method} ${path}: HTTP ${response.status} ${await response.text()}`);
  }
  return response.json();
}

const installation = await github("GET", `/repos/${repository}/installation`);
const { token } = await github("POST", `/app/installations/${installation.id}/access_tokens`, {
  repositories: [repository.split("/")[1]],
});
process.stdout.write(token);
