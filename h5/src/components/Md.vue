<script setup lang="ts">
import MarkdownIt from 'markdown-it'
import { computed } from 'vue'

const props = defineProps<{ source: string }>()

// html: false escapes any raw HTML in the (AI-generated) text, so v-html below is safe.
const md = new MarkdownIt({ html: false, linkify: false, breaks: true })
const defaultLink = md.renderer.rules.link_open
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet('target', '_blank')
  tokens[idx].attrSet('rel', 'noopener noreferrer')
  return defaultLink ? defaultLink(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options)
}

const html = computed(() => md.render(props.source))
</script>

<template>
  <div class="md" v-html="html" />
</template>
