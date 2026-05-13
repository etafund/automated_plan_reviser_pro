#!/usr/bin/env python3
import json
import logging
from pathlib import Path
import jsonschema
import time
import sys

def main():
    root = Path('PLAN/apr-vnext-plan-bundle-v18.0.0')
    contracts_dir = root / 'contracts'
    fixtures_dir = root / 'fixtures'
    logs_dir = Path('tests/logs/v18/contracts')
    logs_dir.mkdir(parents=True, exist_ok=True)
    
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"smoke_test_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
    
    # Also log to stdout
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    formatter = logging.Formatter('%(message)s')
    console.setFormatter(formatter)
    logging.getLogger('').addHandler(console)

    def get_schema_for_fixture(fixture_path):
        data = json.loads(fixture_path.read_text())
        version = data.get('schema_version')
        if not version:
            return None
        base = version.rsplit('.', 1)[0].replace('_', '-')
        if base == "traceability-matrix":
            base = "traceability"
        schema_path = contracts_dir / f"{base}.schema.json"
        if schema_path.exists():
            return schema_path
        return None

    failed = False
    logging.info(f"Validator version: jsonschema {jsonschema.__version__}")
    
    positive_fixtures = [f for f in fixtures_dir.glob('*.json') if f.is_file()]
    negative_fixtures = [f for f in (fixtures_dir / 'negative').glob('*.json') if f.is_file()]
    
    for fixture in positive_fixtures:
        schema = get_schema_for_fixture(fixture)
        if not schema:
            logging.error(f"FAIL [POSITIVE]: {fixture.name} -> No matching schema found or no schema_version")
            failed = True
            continue
        try:
            start_time = time.time()
            jsonschema.validate(json.loads(fixture.read_text()), json.loads(schema.read_text()))
            elapsed = time.time() - start_time
            logging.info(f"PASS [POSITIVE]: {fixture.name} validated against {schema.name} ({elapsed:.3f}s)")
        except jsonschema.ValidationError as e:
            failed = True
            elapsed = time.time() - start_time
            logging.error(f"FAIL [POSITIVE]: {fixture.name} failed against {schema.name} ({elapsed:.3f}s)")
            logging.error(f"  Error: {e.message}")
            logging.error(f"  To debug: python3 -c \"import json, jsonschema; jsonschema.validate(json.load(open('{fixture}')), json.load(open('{schema}')))\"")
            
    for fixture in negative_fixtures:
        schema = get_schema_for_fixture(fixture)
        if not schema:
            logging.error(f"FAIL [NEGATIVE]: {fixture.name} -> No matching schema found or no schema_version")
            failed = True
            continue
        try:
            start_time = time.time()
            jsonschema.validate(json.loads(fixture.read_text()), json.loads(schema.read_text()))
            elapsed = time.time() - start_time
            failed = True
            logging.error(f"FAIL [NEGATIVE]: {fixture.name} UNEXPECTEDLY PASSED against {schema.name} ({elapsed:.3f}s)")
            logging.error(f"  To debug: python3 -c \"import json, jsonschema; jsonschema.validate(json.load(open('{fixture}')), json.load(open('{schema}')))\"")
        except jsonschema.ValidationError as e:
            elapsed = time.time() - start_time
            logging.info(f"PASS [NEGATIVE]: {fixture.name} correctly failed against {schema.name} ({elapsed:.3f}s)")
            logging.info(f"  Expected failure reason: {e.message}")
            
    if failed:
        logging.error("Smoke test FAILED.")
        sys.exit(1)
    else:
        logging.info("Smoke test PASSED.")
        sys.exit(0)

if __name__ == '__main__':
    main()
