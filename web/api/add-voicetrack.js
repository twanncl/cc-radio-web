// api/add-voicetrack.js
// Voegt een pratend stukje toe aan data/voicetracks.json in de repo.
// Zelfde GitHub-configuratie als api/add-song.js.

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Alleen POST is toegestaan" });
  }

  const { name, url } = req.body || {};
  if (!name || !url) {
    return res.status(400).json({ error: "Naam en URL zijn verplicht" });
  }

  const owner = process.env.GITHUB_OWNER;
  const repo = process.env.GITHUB_REPO;
  const branch = process.env.GITHUB_BRANCH || "main";
  const token = process.env.GITHUB_TOKEN;
  const path = "data/voicetracks.json";

  if (!owner || !repo || !token) {
    return res.status(500).json({ error: "Server mist GITHUB_* environment variables" });
  }

  const apiBase = `https://api.github.com/repos/${owner}/${repo}/contents/${path}`;
  const headers = { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" };

  try {
    let list = [];
    let sha;

    const getResp = await fetch(`${apiBase}?ref=${branch}`, { headers });
    if (getResp.ok) {
      const fileData = await getResp.json();
      sha = fileData.sha;
      try {
        list = JSON.parse(Buffer.from(fileData.content, "base64").toString("utf-8"));
        if (!Array.isArray(list)) list = [];
      } catch {
        list = [];
      }
    } else if (getResp.status !== 404) {
      return res.status(502).json({ error: "Kon voicetracks.json niet ophalen" });
    }

    list.push({ name: String(name), url: String(url) });
    const newContent = Buffer.from(JSON.stringify(list, null, 2), "utf-8").toString("base64");

    const putResp = await fetch(apiBase, {
      method: "PUT",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: `Pratend stukje toegevoegd via webpagina: ${name}`,
        content: newContent,
        branch,
        sha,
      }),
    });

    if (!putResp.ok) {
      const errText = await putResp.text();
      return res.status(502).json({ error: "Kon niet wegschrijven naar GitHub", details: errText });
    }

    return res.status(200).json({ success: true });
  } catch (err) {
    return res.status(500).json({ error: String(err) });
  }
}
