require 'spec_helper'
require 'spree/testing_support/preferences'

module Spree
  describe Order do
    let(:user) { create(:user) }
    let!(:store_credit) { create(:store_credit, user: user, amount: 45.00, remaining_amount: 45.00)}
    let(:line_item) { mock_model(LineItem, :variant => double('variant'), :quantity => 5, :price => 10) }
    let(:order) { create(:order, user: user) }

    before do
      reset_spree_preferences { |config| config.use_store_credit_minimum = 0 }
    end

    context "process_store_credit" do
      before do
        order.stub(:user => user, :total => 50 )
      end

      it "should create store credit adjustment when user has sufficient credit" do
        order.store_credit_amount = 5.0
        order.save
        order.adjustments.store_credits.size.should == 1
        order.store_credit_amount.should == 5.0
      end

      it "should only create adjustment with amount equal to users total credit" do
        order.store_credit_amount = 50.0
        order.save
        order.store_credit_amount.should == 45.00
      end

      it "should only create adjustment with amount equal to order total" do
        user.stub(:store_credits_total => 100.0)
        order.store_credit_amount = 90.0
        order.save
        order.store_credit_amount.should == 50.00
      end

      it "should not create adjustment when user does not have any credit" do
        user.stub(:store_credits_total => 0.0)
        order.store_credit_amount = 5.0
        order.save
        order.adjustments.store_credits.size.should == 0
        order.store_credit_amount.should == 0.0
      end

      it "should update order totals if credit is applied" do
        pending
        order.should_receive(:update_totals).twice
        order.store_credit_amount = 5.0
        order.save
      end

      it "should update payment amount if credit is applied" do
        order.stub_chain(:pending_payments, :first => double('payment', :payment_method => double('payment method', :payment_profiles_supported? => true)))
        order.pending_payments.first.should_receive(:amount=)
        order.store_credit_amount = 5.0
        order.save
      end

      it "should create negative adjustment" do
        order.store_credit_amount = 5.0
        order.save
        order.adjustments[0].amount.should == -5.0
      end

      it "should process credits if order total is already zero" do
        order.stub(:total => 0)
        order.store_credit_amount = 5.0
        order.should_receive(:process_store_credit)
        order.save
        order.adjustments.store_credits.size.should == 0
        order.store_credit_amount.should == 0.0
      end

      context "with an existing adjustment" do
        before { order.adjustments.store_credits.create(:label => I18n.t(:store_credit) , :amount => -10) }

        it "should decrease existing adjustment if specific amount is less than adjustment amount" do
          order.store_credit_amount = 5.0
          order.save
          order.adjustments.store_credits.size.should == 1
          order.store_credit_amount.should == 5.0
        end

        it "should increase existing adjustment if specified amount is greater than adjustment amount" do
          order.store_credit_amount = 25.0
          order.save
          order.adjustments.store_credits.size.should == 1
          order.store_credit_amount.should == 25.0
        end

        it "should destroy the adjustment if specified amount is zero" do
          order.store_credit_amount = 0.0
          order.save
          order.adjustments.store_credits.size.should == 0
          order.store_credit_amount.should == 0.0
        end

        it "should decrease existing adjustment when existing credit amount is equal to the order total" do
          order.stub(:total => 10)
          order.store_credit_amount = 5.0
          order.save
          order.adjustments.store_credits.size.should == 1
          order.store_credit_amount.should == 5.0
        end
      end

    end

    context "store_credit_amount" do
      it "should return total for all store credit adjustments applied to order" do
        order.adjustments.store_credits.create(:label => I18n.t(:store_credit) , :amount => -10)
        order.adjustments.store_credits.create(:label => I18n.t(:store_credit) , :amount => -5)

        order.store_credit_amount.should == BigDecimal.new('15')
      end
    end

    context "consume_users_credit" do
      let(:store_credit_1) { mock_model(StoreCredit, :amount => 100, :remaining_amount => 100) }
      let(:store_credit_2) { mock_model(StoreCredit, :amount => 10, :remaining_amount => 5) }
      let(:store_credit_3) { mock_model(StoreCredit, :amount => 60, :remaining_amount => 50 ) }

      before { order.stub(:completed? => true, :store_credit_amount => 35, :total => 50) }

      it "should reduce remaining amount on a single credit when that credit satisfies the entire amount" do
        user.stub(:store_credits => [store_credit_1])
        store_credit_1.should_receive(:remaining_amount=).with(65)
        store_credit_1.should_receive(:save)
        order.send(:consume_users_credit)
      end

      it "should reduce remaining amount on a multiple credits when a single credit does not satisfy the entire amount" do
        order.stub(:store_credit_amount => 55)
        user.stub(:store_credits => [store_credit_2, store_credit_3])
        store_credit_2.should_receive(:update_attribute).with(:remaining_amount, 0)
        store_credit_3.should_receive(:update_attribute).with(:remaining_amount, 0)
        order.send(:consume_users_credit)
      end

      it "should call consume_users_credit after transition to complete" do
        pending
        new_order = Order.new()
        new_order.state = :confirm
        new_order.should_receive(:consume_users_credit).at_least(1).times
        new_order.next!
        new_order.state.should == 'complete'
      end

      # regression
      it 'should do nothing on guest checkout' do
        order.stub(:user => nil)
        expect {
          order.send(:consume_users_credit)
        }.to_not raise_error
      end
    end


    context "ensure_sufficient_credit" do
      let(:order) { create(:completed_order_with_totals, store_credit_amount: 35, user: user)}
      let!(:payment) { create(:payment, order: order, amount: 40, state: 'completed')}

      before do
        order.adjustments.store_credits.create(label: I18n.t(:store_credit) , amount: -10, eligible: true)
        order.update!
      end

      it "should do nothing when user has credits" do
        order.adjustments.store_credits.should_not_receive(:destroy_all)
        order.should_not_receive(:update!)
        order.send(:ensure_sufficient_credit)
      end

      context "when user no longer has sufficient credit to cover entire credit amount" do
        before do
          store_credit.remaining_amount = 0.0
          store_credit.save!
          user.reload
        end

        it "should destroy all store credit adjustments" do
          order.adjustment_total.should eq(-10)
          order.total.should eq(40)
          order.send(:ensure_sufficient_credit)
          order.adjustments.store_credits.size.should == 0
          order.reload
          order.adjustment_total.should eq(0)
        end

        it "should update the order's payment state" do
          order.payment_state.should eq('paid')
          order.send(:ensure_sufficient_credit)
          order.reload
          order.payment_state.should eq('balance_due')
        end
      end

    end

    context "process_payments!" do

      it "should return false when total is greater than zero and payments are empty" do
        order.stub(:pending_payments => [])
        order.process_payments!.should be_false
      end

      it "should process payment when total is zero and payments is not empty" do
        order.stub(:pending_payments => [mock_model(Payment)])
        order.should_receive(:process_payments_without_credits!)
        order.process_payments!
      end

    end

    context "when minimum item total is set" do
      before do
        order.stub(:item_total => 50)
        order.instance_variable_set(:@store_credit_amount, 25)
      end

      context "when item total is less than limit" do
        before { reset_spree_preferences { |config| config.use_store_credit_minimum = 100 } }

        it "should be invalid" do
          order.valid?.should be_false
          order.errors.should_not be_nil
        end

        it "should be valid when store_credit_amount is 0" do
        order.instance_variable_set(:@store_credit_amount, 0)
          order.stub(:item_total => 50)
          order.valid?.should be_true
          order.errors.count.should == 0
        end

      end

      describe "when item total is greater than limit" do
        before { reset_spree_preferences { |config| config.use_store_credit_minimum = 10 } }

        it "should be valid when item total is greater than limit" do
          order.valid?.should be_true
          order.errors.count.should == 0
        end

      end

    end
  end
end
