#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"


void app_main(void)
{
  printf("Setup print\n");
  
  while (1) {
    printf("Loop print\n");
    vTaskDelay(pdMS_TO_TICKS(1000)); // Delay for 1000 milliseconds
  }
}