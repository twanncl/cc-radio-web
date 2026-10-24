// api/upload.js
// Ontvangt een geüpload bestand (al geconverteerd naar .dfpwm) en host
// het automatisch, zodat jij niet meer zelf naar catbox.moe hoeft te
// gaan. Geeft de directe URL terug.

import formidable from "formidable";
import fs from "fs";

export const config = {
  api: { bodyParser: false },
};

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Alleen POST is toegestaan" });
  }

  try {
    const form = formidable({ maxFileSize: 20 * 1024 * 1024 }); // 20MB marge
    const [, files] = await form.parse(req);

    const uploaded = Array.isArray(files.file) ? files.file[0] : files.file;
    if (!uploaded) {
      return res.status(400).json({ error: "Geen bestand ontvangen" });
    }

    const fileBuffer = fs.readFileSync(uploaded.filepath);

    const catboxForm = new FormData();
    catboxForm.append("reqtype", "fileupload");
    catboxForm.append(
      "fileToUpload",
      new Blob([fileBuffer]),
      uploaded.originalFilename || "upload.dfpwm"
    );

    const catboxResp = await fetch("https://catbox.moe/user/api.php", {
      method: "POST",
      body: catboxForm,
    });

    const text = (await catboxResp.text()).trim();

    if (!catboxResp.ok || !text.startsWith("http")) {
      return res.status(502).json({ error: "Hosten van het bestand is mislukt", details: text });
    }

    return res.status(200).json({ url: text });
  } catch (err) {
    return res.status(500).json({ error: String(err) });
  }
}
