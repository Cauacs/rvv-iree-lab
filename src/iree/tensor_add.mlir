module {
  func.func @add(
      %lhs: tensor<4xf32>,
      %rhs: tensor<4xf32>
  ) -> tensor<4xf32> attributes {iree.module.export} {
    %sum = arith.addf %lhs, %rhs : tensor<4xf32>
    return %sum : tensor<4xf32>
  }
}
