const ports = @import("ports.zig");
const schema = ports.schema;
const store = ports.store;

pub const Person = schema.Person;
pub const Sighting = schema.Sighting;
pub const FaceEmbeddingRef = schema.FaceEmbeddingRef;
pub const MemoryStore = store.MemoryStore;
