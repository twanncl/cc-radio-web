// api/add-song.js
// Serverless function (draait op Vercel). Voegt een nummer toe aan
// data/playlist.json in je GitHub-repo via de GitHub Contents API.
//
// Vereiste environment variables (instellen in Vercel):
//   GITHUB_OWNER  - je GitHub-gebruikersnaam
//   GITHUB_REPO   - de repo-naam
//   GITHUB_BRANCH - meestal "main"
//   GITHUB_TOKEN  - een Personal Access Token met schrijfrechten op de repo

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Alleen POST is toegestaan" });
  }

  const { name, artist, url, category, tempo, style, holiday, skipBytes } = req.body || {};

  if (!name || !artist || !url) {
    return res.status(400).json({ error: "Naam, artiest en URL zijn verplicht" });
  }

  const owner = process.env.GITHUB_OWNER;
  const repo = process.env.GITHUB_REPO;
  const branch = process.env.GITHUB_BRANCH || "main";
  const token = process.env.GITHUB_TOKEN;
  const path = "data/playlist.json";

  if (!owner || !repo || !token) {
    return res.status(500).json({
      error: "Server is niet goed geconfigureerd (ontbrekende GITHUB_* environment variables)",
    });
  }

  const apiBase = `https://api.github.com/repos/${owner}/${repo}/contents/${path}`;
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
  };

  try {
    // Huidige bestandsinhoud + sha ophalen (sha is nodig om te mogen overschrijven)
    let playlist = [];
    let sha;

    const getResp = await fetch(`${apiBase}?ref=${branch}`, { headers });
    if (getResp.ok) {
      const fileData = await getResp.json();
      sha = fileData.sha;
      const content = Buffer.from(fileData.content, "base64").toString("utf-8");
      try {
        playlist = JSON.parse(content);
        if (!Array.isArray(playlist)) playlist = [];
      } catch {
        playlist = [];
      }
    } else if (getResp.status !== 404) {
      const errText = await getResp.text();
      return res.status(502).json({ error: "Kon playlist.json niet ophalen", details: errText });
    }

    playlist.push({
      name: String(name),
      artist: String(artist),
      url: String(url),
      category: category || "C",
      tempo: tempo || "medium",
      style: style || "",
      holiday: (holiday || "").toLowerCase(),
      skipBytes: Number(skipBytes) || 0,
    });

    const newContent = Buffer.from(JSON.stringify(playlist, null, 2), "utf-8").toString("base64");

    const putResp = await fetch(apiBase, {
      method: "PUT",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: `Nummer toegevoegd via webpagina: ${name} - ${artist}`,
        content: newContent,
        branch,
        sha, // ontbreekt bij een eerste keer (404 hierboven), dat is prima
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
