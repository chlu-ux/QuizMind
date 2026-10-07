<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import Md from '@/components/Md.vue'
import { lessonBlocks } from '@/quiz/lessons'

const props = defineProps<{ text: string; cover?: boolean }>()

const blocks = computed(() => lessonBlocks(props.text))
const root = ref<HTMLElement | null>(null)
// Sentences the reader has uncovered, by "block/sentence"; reset whenever the text or the mode changes.
const shown = ref(new Set<string>())

function reset() {
  shown.value = new Set()
  // List items and table cells are plain rendered HTML; their uncovered state is a class on the element.
  root.value?.querySelectorAll('.shown').forEach((el) => el.classList.remove('shown'))
}
watch(() => [props.text, props.cover], reset, { flush: 'post' })

function toggle(key: string) {
  if (!props.cover) return
  const next = new Set(shown.value)
  if (!next.delete(key)) next.add(key)
  shown.value = next
}

/**
 * Covering a list or a table hides what is to be recalled and leaves the cue: every list item,
 * and every table cell but the first of its row. A tap uncovers the item or cell; an item inside a
 * covered item is uncovered by uncovering the outer one first.
 */
function onTap(e: MouseEvent) {
  if (!props.cover || !(e.target instanceof Element)) return
  const cell = e.target.closest('td')
  if (cell && cell.cellIndex > 0) return void cell.classList.toggle('shown')
  let li = e.target.closest('li')
  if (!li || li.closest('.sentences')) return
  for (let outer = li.parentElement?.closest('li'); outer && !outer.classList.contains('shown'); outer = li.parentElement?.closest('li')) {
    li = outer
  }
  li.classList.toggle('shown')
}
</script>

<template>
  <div ref="root" class="lesson-body" :class="{ covering: cover }" @click="onTap">
    <template v-for="(b, i) in blocks" :key="i">
      <ul v-if="b.kind === 'prose'" class="sentences">
        <li
          v-for="(s, j) in b.sentences"
          :key="j"
          class="sentence"
          :class="{ covered: cover && !shown.has(i + '/' + j), tappable: cover }"
          @click.stop="toggle(i + '/' + j)"
        >
          <Md :source="s" />
        </li>
      </ul>
      <Md v-else :source="b.source" />
    </template>
  </div>
</template>
