import { ApiError } from "./errors.js";
let csrf = "";
export function setCsrf(value: string) {
	csrf = value;
}

export async function api<T>(
	path: string,
	method = "GET",
	data?: unknown,
): Promise<T> {
	const res = await fetch("/api" + path, {
		method,
		headers: { "content-type": "application/json", "x-csrf-token": csrf },
		body: data === undefined ? undefined : JSON.stringify(data),
	});
	const value = await res.json();
	if (!res.ok) throw new ApiError(value.error || "Request failed", res.status);
	return value;
}

export async function uploadImage(cardId: number, file: File) {
	const response = await fetch(`/api/cards/${cardId}/images`, {
		method: "POST",
		headers: {
			"content-type": file.type,
			"x-file-name": encodeURIComponent(file.name),
			"x-csrf-token": csrf,
		},
		body: file,
	});
	const value = await response.json();
	if (!response.ok)
		throw new ApiError(value.error || "Request failed", response.status);
	return value;
}
