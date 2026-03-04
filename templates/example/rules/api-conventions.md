# API Conventions

- Use plural nouns for resource endpoints (e.g., /users, /orders)
- Return 201 for successful resource creation
- Return 204 for successful deletion
- Use consistent error response format: { "error": { "code": "...", "message": "..." } }
- Include pagination for list endpoints
