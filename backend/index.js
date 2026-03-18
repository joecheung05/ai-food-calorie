import express from 'express';
import cors from 'cors';
import { GoogleAuth } from 'google-auth-library';
import fetch from 'node-fetch';

const app = express();
app.use(cors());

app.use(express.json({ limit: '10mb' }));

const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });

app.post('/analyze', async (req, res) => {
  try {
    const { imageBase64 } = req.body;
    if (!imageBase64) return res.status(400).json({ error: 'imageBase64 required' });

    const client = await auth.getClient();
    const accessToken = await client.getAccessToken();
    const project = '1005167792462';
    const location = 'us-central1';
    const endpoint = 'YOUR_ENDPOINT_ID'; // 修改為你 Vertex AI endpoint

    const apiUrl = `https://us-central1-aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/endpoints/${endpoint}:predict`;
    const r = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        instances: [
          { content: imageBase64 }
        ]
      }),
    });
    const data = await r.json();
    res.json(data);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message || err.toString() });
  }
});

app.listen(3000, () => console.log('Server running on http://localhost:3000'));