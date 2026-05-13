#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

VERSION = 'v18.0.0'

def check_conformance(schema_path):
    errors = []
    try:
        with open(schema_path, 'r', encoding='utf-8') as f:
            schema = json.load(f)
    except Exception as e:
        return [f"FAILED TO PARSE: {e}"]

    # 1. $schema MUST be Draft 2020-12
    if schema.get('$schema') != "https://json-schema.org/draft/2020-12/schema":
        errors.append(f"MUST use Draft 2020-12 $schema, got: {schema.get('$schema')}")

    # 2. $id MUST be present and match filename
    id_val = schema.get('$id')
    if not id_val:
        errors.append("MUST have $id")
    elif not id_val.endswith(schema_path.name):
        errors.append(f"$id MUST end with filename {schema_path.name}, got: {id_val}")

    # 3. x-bundle-version MUST be v18.0.0
    if schema.get('x-bundle-version') != VERSION:
        errors.append(f"MUST have x-bundle-version: {VERSION}, got: {schema.get('x-bundle-version')}")

    # 4. title MUST be present
    if not schema.get('title'):
        errors.append("MUST have title")

    # 5. type MUST be object
    if schema.get('type') != 'object':
        errors.append(f"MUST have type: object, got: {schema.get('type')}")

    # 6. additionalProperties MUST be true
    if schema.get('additionalProperties') is not True:
        errors.append(f"MUST have additionalProperties: true, got: {schema.get('additionalProperties')}")

    # 7. bundle_version property constraint
    props = schema.get('properties', {})
    bv_prop = props.get('bundle_version')
    if bv_prop:
        if bv_prop.get('const') != VERSION:
            errors.append(f"bundle_version property MUST have const: {VERSION}")

    # 8. schema_version property constraint
    sv_prop = props.get('schema_version')
    if sv_prop:
        expected_sv = schema_path.name.replace('.schema.json', '').replace('-', '_') + ".v1"
        # Special case for traceability -> traceability_matrix
        if schema_path.name == 'traceability.schema.json':
            expected_sv = "traceability_matrix.v1"
            
        actual_sv = sv_prop.get('const')
        if actual_sv != expected_sv:
             errors.append(f"schema_version property MUST have const: {expected_sv}, got: {actual_sv}")

    return errors

def main():
    root = Path('PLAN/apr-vnext-plan-bundle-v18.0.0/contracts')
    schemas = list(root.glob('*.schema.json'))
    
    if not schemas:
        print("No schemas found.")
        sys.exit(1)

    print(f"Checking {len(schemas)} schemas for v18 conformance...")
    total_errors = 0
    results = []

    for s_path in sorted(schemas):
        errors = check_conformance(s_path)
        status = "PASS" if not errors else "FAIL"
        results.append({
            'file': s_path.name,
            'status': status,
            'errors': errors
        })
        if errors:
            total_errors += len(errors)
            print(f"\n[FAIL] {s_path.name}:")
            for e in errors:
                print(f"  - {e}")
        else:
            print(f"[PASS] {s_path.name}")

    print(f"\nSummary: {len(schemas)} checked, {total_errors} errors found.")
    
    # Generate compliance matrix
    print("\n| Schema | Status | Errors |")
    print("|--------|--------|--------|")
    for r in results:
        err_count = len(r['errors'])
        print(f"| {r['file']} | {r['status']} | {err_count} |")

    if total_errors > 0:
        sys.exit(1)

if __name__ == '__main__':
    main()
