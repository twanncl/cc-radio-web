// api/library.js
// Leest de huidige playlist/pratende stukjes/jingles van GitHub, voor
// het overzicht op de website.

async function fetchJSON(owner, repo, branch, token, path) {
  const r = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}`,
    { headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" } }
  );
  if (!r.ok) return [];
  const data = await r.json();
  try {
    const parsed = JSON.parse(Buffer.from(data.content, "base64").toString("utf-8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export default async function handler(req, res) {
  const owner = process.env.GITHUB_OWNER;
  const repo = process.env.GITHUB_REPO;
  const branch = process.env.GITHUB_BRANCH || "main";
  const token = process.env.GITHUB_TOKEN;

  if (!owner || !repo || !token) {
    return res.status(500).json({ error: "Server mist GITHUB_* environment variables" });
  }

  try {
    const [playlist, voicetracks, jingles] = await Promise.all([
      fetchJSON(owner, repo, branch, token, "data/playlist.json"),
      fetchJSON(owner, repo, branch, token, "data/voicetracks.json"),
      fetchJSON(owner, repo, branch, token, "data/jingles.json"),
    ]);

    return res.status(200).json({ playlist, voicetracks, jingles });
  } catch (err) {
    return res.status(500).json({ error: String(err) });
  }
}
