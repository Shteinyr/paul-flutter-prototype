"""Import the versioned ESCO English preferred labels used by skill inputs."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from urllib.parse import urlencode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='v1.2.1')
    args = parser.parse_args()
    skills = {}
    offset = 0
    total = None
    while total is None or offset * 1000 < total:
        query = urlencode({
            'type': 'skill', 'language': 'en', 'full': 'false',
            'limit': 1000, 'offset': offset, 'selectedVersion': args.version,
            'viewObsolete': 'false',
        })
        response = subprocess.check_output([
            'curl', '--fail', '--silent', '--show-error', '--max-time', '60',
            '--retry', '2', 'https://ec.europa.eu/esco/api/search?' + query,
        ])
        page = json.loads(response)
        if total is not None and page['total'] != total:
            raise ValueError('ESCO total changed during import')
        total = page['total']
        rows = page['_embedded']['results']
        if not rows:
            raise ValueError('ESCO returned an incomplete page')
        for row in rows:
            label = row['preferredLabel']['en']
            uri = row['uri']
            if not uri.startswith('http://data.europa.eu/esco/skill/'):
                raise ValueError('Unexpected concept URI')
            if uri in skills:
                raise ValueError('Repeated concept in paged import')
            skills[uri] = label
        print(f'Imported {len(skills)} / {total}', flush=True)
        offset += 1
    if len(skills) != total:
        raise ValueError('ESCO import count mismatch')
    entries = [[uri.rsplit('/', 1)[-1], label]
               for uri, label in sorted(skills.items(), key=lambda item: (item[1].lower(), item[0]))]
    dataset = {
        'source': 'ESCO', 'version': args.version, 'language': 'en',
        'source_url': 'https://esco.ec.europa.eu/en/use-esco',
        'terms_url': 'https://esco.ec.europa.eu/en/about-esco/faq?page=1',
        'attribution': 'This service uses the ESCO classification of the European Commission.',
        'entries': entries,
    }
    destination = Path(__file__).resolve().parent.parent / 'assets/skills/esco_en.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(dataset, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    destination.write_bytes(encoded)
    print(f'{len(entries)} labels, {len(encoded)} bytes, SHA256 {hashlib.sha256(encoded).hexdigest()}')


if __name__ == '__main__':
    main()
