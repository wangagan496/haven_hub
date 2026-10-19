// 新增 HTTP 路径先在此定义；旧路由保持既有地址。
export const RepairPath = {
  slots: '/repair/slots',
  capacities: '/management/repair-capacities',
  capacityWeekdays: '/management/repair-capacities/weekdays',
  capacityWeekday: '/management/repair-capacities/weekdays/:weekday',
  capacityDate: '/management/repair-capacities/:date',
  propose: '/management/repairs/:id/reschedule',
  queue: '/management/repair-queue',
  priority: '/management/repairs/:id/priority',
  shiftSuggestions: '/management/repair-shift-suggestions',
  shift: '/management/repairs/:id/shift',
  dispatchOptions: '/management/repairs/:id/dispatch-options',
  dispatch: '/management/repairs/:id/dispatch',
} as const;
