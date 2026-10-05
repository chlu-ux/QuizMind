<script setup lang="ts">
import MarkdownIt from 'markdown-it'
import { computed } from 'vue'
import { openImage } from '@/core/lightbox'
import { mediaUrl } from '@/quiz/media'

const props = defineProps<{ source: string }>()

// html: false escapes any raw HTML in the (AI-generated) text, so v-html below is safe.
const md = new MarkdownIt({ html: false, linkify: false, breaks: true })
const defaultLink = md.renderer.rules.link_open
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet('target', '_blank')
  tokens[idx].attrSet('rel', 'noopener noreferrer')
  return defaultLink ? defaultLink(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options)
}

// Pictures are uploaded to the server and written as `media:<id>`; point them at the API.
md.renderer.rules.image = (tokens, idx) => {
  const t = tokens[idx]
  const alt = md.utils.escapeHtml(t.content)
  const src = md.utils.escapeHtml(mediaUrl(t.attrGet('src') ?? ''))
  return `<img class="qimg" src="${src}" alt="${alt}" loading="lazy">`
}

function onClick(e: MouseEvent) {
  if (e.target instanceof HTMLImageElement) openImage(e.target.src, e.target.alt)
}

const html = computed(() => md.render(props.source))
</script>

<template>
  <div class="md" @click="onClick" v-html="html" />
</template>
