// api/detect-silence.js
// Analyseert een .dfpwm bestand op stilte aan het begin. Dit gebeurt
// hier (op Vercel, met volledige rekenkracht) in plaats van op de
// CC:Tweaked-computer, die daar eerder problemen mee had (te weinig
// rekentijd per tick, en per ongeluk zachte muziek voor stilte aanzien).
//
// Methode: DFPWM codeert bijna-stilte als een strak afwisselend
// bitpatroon (dicht bij 0x55/0xAA). We tellen hoeveel bytes aan het
// begin aan dat patroon voldoen - dat is een bewust streng/conservatief
// criterium, zodat zachte-maar-echte muziek niet per ongeluk als
// stilte wordt gezien (dat was precies de bug die we eerder hadden).

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Alleen POST is toegestaan" });
  }

  const { url } = req.body || {};
  if (!url) {
    return res.status(400).json({ error: "url is verplicht" });
  }

  try {
    const resp = await fetch(url);
    if (!resp.ok) {
      return res.status(502).json({ error: "Kon het bestand niet ophalen" });
    }
    const buf = Buffer.from(await resp.arrayBuffer());

    // Bytes die "bijna stilte" representeren in DFPWM (strak
    // afwisselend patroon rond het midden van de range)
    const isQuiet = (b) =>
      b === 0x55 || b === 0xaa || b === 0x54 || b === 0xab || b === 0x56 || b === 0xa9;

    let count = 0;
    while (count < buf.length && isQuiet(buf[count])) count++;

    const MIN_BYTES = 4800; // ~0.8 sec - anders is het de moeite niet waard
    const skipBytes = count >= MIN_BYTES ? count : 0;
    const skipSeconds = skipBytes / 6000; // 1 byte dfpwm = 8 samples @ 48kHz -> bytes/6000 = sec

    return res.status(200).json({
      skipBytes,
      skipSeconds: Number(skipSeconds.toFixed(2)),
      fileSizeBytes: buf.length,
    });
  } catch (err) {
    return res.status(500).json({ error: String(err) });
  }
}
