<script setup lang="ts">
import MarkdownIt from 'markdown-it'
import { computed } from 'vue'
import { openImage } from '@/core/lightbox'
import { mediaUrl } from '@/quiz/media'
import { parseAgentLink } from '@/quiz/agentLinks'
import { checkSvg, splitSvg, svgDataUrl } from '@/quiz/svg'

const props = defineProps<{ source: string; agentLinks?: boolean }>()
const emit = defineEmits<{ link: [href: string] }>()

// html: false escapes any raw HTML in the (AI-generated) text, so v-html below is safe.
const md = new MarkdownIt({ html: false, linkify: false, breaks: true })
const defaultLink = md.renderer.rules.link_open
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  const href = tokens[idx].attrGet('href') ?? ''
  if ((env as { agentLinks?: boolean }).agentLinks && parseAgentLink(href)) {
    // `lesson:` / `question:` links of the assistant are opened by the page, not the browser.
    tokens[idx].attrSet('data-agent-link', href)
    tokens[idx].attrSet('href', '#')
  } else {
    tokens[idx].attrSet('target', '_blank')
    tokens[idx].attrSet('rel', 'noopener noreferrer')
  }
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
  if (!(e.target instanceof Element)) return
  const link = e.target.closest('a[data-agent-link]')
  if (link) {
    e.preventDefault()
    emit('link', link.getAttribute('data-agent-link') ?? '')
    return
  }
  if (e.target instanceof HTMLImageElement) openImage(e.target.src, e.target.alt)
}

/** A diagram the assistant drew: shown as a picture when it passes the whitelist, else as code. */
function renderSvg(source: string): string {
  const svg = checkSvg(source)
  if (!svg) return md.render('```\n' + source + '\n```')
  return `<img class="qimg" src="${md.utils.escapeHtml(svgDataUrl(svg))}" alt="AI 绘制的示意图">`
}

const html = computed(() =>
  splitSvg(props.source)
    .map((p) => (p.svg ? renderSvg(p.text) : md.render(p.text, { agentLinks: props.agentLinks })))
    .join(''),
)
</script>

<template>
  <div class="md" @click="onClick" v-html="html" />
</template>
