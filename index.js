const express = require('express');
const cors = require('cors');
const app = express();
const bodyParser = require('body-parser');
const clustalOmega = require('clustal-omega-wrapper');
const path = require('path');

clustalOmega.setCustomLocation(path.join(__dirname, './bin'));

app.use(cors());
app.use(bodyParser.json());

app.get('/', (req, res) => {
	res.status(200).json({
		version: 1.0,
		api_working: true,
		error: false
	});
});

app.post('/align-sequence', (req, res) => {
	if (!req.body.sequence) {
		return res
			.status(400)
			.json({ error: true, message: 'No sequence sent!' })
	}

  clustalOmega.alignSeqString(req.body.sequence, 'fasta', (err, data) => {
		if (err) {
			res.status(400).json({ error: err });
		} else {
			res.status(200).json({ error: false, data: data });
		}
	});
});

app.listen(process.env.PORT || 3000, () => {
	console.log('Server started!');
});