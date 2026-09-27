// Minimal JSON schema subset validator (type, required, properties, enum,
// items) so reply validation works without a runtime dependency.

export function validateSchema(schema, location = '$') {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new Error(`${location}: reply schema must be an object`);
  }
  if (schema.type !== undefined && !['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'].includes(schema.type)) {
    throw new Error(`${location}: unsupported schema type`);
  }
  if (schema.required !== undefined && (!Array.isArray(schema.required) || schema.required.some(key => typeof key !== 'string'))) {
    throw new Error(`${location}: required must be an array of property names`);
  }
  if (schema.enum !== undefined && (!Array.isArray(schema.enum) || !schema.enum.length)) {
    throw new Error(`${location}: enum must be a nonempty array`);
  }
  if (schema.properties !== undefined) {
    if (!schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties)) {
      throw new Error(`${location}: properties must be an object`);
    }
    for (const [key, child] of Object.entries(schema.properties)) validateSchema(child, `${location}.${key}`);
  }
  if (schema.items !== undefined) validateSchema(schema.items, `${location}[]`);
}

function typeOf(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value === 'object' ? 'object' : typeof value;
}

function check(value, schema, path, errors) {
  if (!schema || typeof schema !== 'object') return;
  if (schema.enum) {
    const matched = schema.enum.some((item) => JSON.stringify(item) === JSON.stringify(value));
    if (!matched) errors.push(`${path}: value is not one of the enum values`);
  }
  if (schema.type) {
    const actual = typeOf(value);
    const ok = schema.type === 'integer'
      ? actual === 'number' && Number.isInteger(value)
      : actual === schema.type;
    if (!ok) {
      errors.push(`${path}: expected ${schema.type}, got ${actual}`);
      return;
    }
  }
  if (typeOf(value) === 'object' && (schema.required || schema.properties)) {
    for (const key of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(`${path}.${key}: required property is missing`);
      }
    }
    for (const [key, subschema] of Object.entries(schema.properties || {})) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        check(value[key], subschema, `${path}.${key}`, errors);
      }
    }
  }
  if (Array.isArray(value) && schema.items) {
    value.forEach((item, index) => check(item, schema.items, `${path}[${index}]`, errors));
  }
}

// Validates a model reply as JSON, optionally against a schema. Returns
// { ok, value } or { ok: false, errors }.
export function validateReply(text, schema) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    return { ok: false, errors: [`reply is not valid JSON: ${error.message}`] };
  }
  if (!schema) return { ok: true, value };
  const errors = [];
  check(value, schema, '$', errors);
  return errors.length ? { ok: false, errors } : { ok: true, value };
}
