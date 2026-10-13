export function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
export class ApiError extends Error {
	status: number;
	constructor(message: string, status: number) {
		super(message);
		this.status = status;
	}
}
