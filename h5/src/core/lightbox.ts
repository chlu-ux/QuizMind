import { reactive } from 'vue'

/** The picture currently shown full screen; an empty `src` means none. */
export const lightbox = reactive({ src: '', alt: '' })

export function openImage(src: string, alt = ''): void {
  lightbox.src = src
  lightbox.alt = alt
}

export function closeImage(): void {
  lightbox.src = ''
}
