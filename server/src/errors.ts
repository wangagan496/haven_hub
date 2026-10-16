export class ApiError extends Error {
  constructor(public readonly status: number, public readonly code: number, message: string) {
    super(message);
  }
}
export function requireValue(value: unknown, message: string): asserts value {
  if (!value) throw new ApiError(200, 40001, message);
}
