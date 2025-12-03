// V30 (8086) Test Program for Pico Monitor, written in C.
// This version includes stack initialization and is K&R-compatible for bcc.

// Forward declaration for the main logic.
void main();

// The _start function will be the entry point for the program.
void _start() {
    // Use bcc's inline assembler to set the stack pointer to a safe address.
    // as86 (bcc's assembler) uses '#' for immediate values.
    asm("mov sp, #0x8000");
    
    // After setting up the stack, call the main C function.
    main();
}

void hlt(){
  asm("hlt");
}

unsigned char mem;
void out_mem(){
  asm("mov al, _mem");
  asm("out 5, al");
}

// Main C logic, same as before.
void main() {
  // Declare all variables at the top of the function.
  unsigned char a;
  unsigned char b;
  unsigned char c;

  // Assign values to the variables.
  a = 1;
  b = 2;

  // Perform the calculation and store the result.
  c = a + b;
  mem = c;

  // out_mem();  // ここでCALLすると暴走する？
  asm("mov al, _mem");
  asm("out 5, al");

  hlt();
}
